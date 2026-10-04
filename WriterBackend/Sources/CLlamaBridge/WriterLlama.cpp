#include "include/WriterLlama.h"
#include "vendor/llama.h"
#include <dlfcn.h>
#include <atomic>
#include <chrono>
#include <vector>
#include <string>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <mutex>
#include <condition_variable>
#include <mach-o/dyld.h>
#include <limits.h>

#define FUNCTIONS(X) \
 X(llama_model_default_params) X(llama_context_default_params) X(llama_model_load_from_file) \
 X(llama_init_from_model) X(llama_model_free) X(llama_free) X(llama_model_get_vocab) \
 X(llama_tokenize) X(llama_batch_get_one) X(llama_decode) X(llama_sampler_init_greedy) \
 X(llama_sampler_sample) X(llama_sampler_free) X(llama_vocab_is_eog) X(llama_token_to_piece) \
 X(llama_log_set) X(llama_backend_init)
struct wr_runtime {
    void * lib=nullptr; llama_model * model=nullptr;
    std::atomic<bool> cancelled{false};
    std::atomic<int> phase{0};
    std::atomic<int> generation_status{-1};
    wr_pause_predicate should_pause=nullptr;
    void * pause_data=nullptr;
    std::mutex pause_mutex;
    std::condition_variable pause_changed;
    int offloaded=-1,total=-1;
    #define MEMBER(name) decltype(&name) name##_p=nullptr;
    FUNCTIONS(MEMBER)
    #undef MEMBER
};
static void quiet(enum ggml_log_level,const char *,void *) {}
static std::timed_mutex load_mutex;
struct wr_load_ticket {std::atomic<bool> cancelled{false};std::atomic<int> phase{0};};
wr_load_ticket * wr_load_ticket_create(){return new wr_load_ticket();}
void wr_load_ticket_cancel(wr_load_ticket * t){if(t)t->cancelled=true;}
int wr_load_ticket_cancelled(wr_load_ticket * t){return !t||t->cancelled.load();}
int wr_load_ticket_phase(wr_load_ticket * t){return t?t->phase.load():-1;}
void wr_load_ticket_destroy(wr_load_ticket * t){delete t;}
int wr_runtime_image_conflicts(const char * name,const char * library) {
    if(!name||!library)return 1;
    std::string directory(library);directory=directory.substr(0,directory.find_last_of('/'));
    const char * base=strrchr(name,'/');base=base?base+1:name;
    if(strncmp(base,"libllama",8)!=0&&strncmp(base,"libggml",7)!=0)return 0;
    char actual[PATH_MAX],expected[PATH_MAX];std::string target=directory+"/"+base;
    return !realpath(name,actual)||!realpath(target.c_str(),expected)||strcmp(actual,expected)!=0;
}
static bool conflicting_images(const char * library) {
    for(uint32_t i=0;i<_dyld_image_count();i++) {
        const char * name=_dyld_get_image_name(i);if(!name)continue;
        if(wr_runtime_image_conflicts(name,library))return true;
    }
    return false;
}
// Retain only numeric offload counts, never a model log line or prompt content.
static void load_evidence(enum ggml_log_level,const char * text,void * data) {
    auto r=static_cast<wr_runtime *>(data);
    const char * marker=text ? strstr(text,"offloaded "):nullptr;
    int layers,total;
    if(marker&&sscanf(marker,"offloaded %d/%d layers",&layers,&total)==2&&layers>=0&&total>=layers&&total<=1024) {r->offloaded=layers;r->total=total;}
}
static bool abort_inference(void * p) {return static_cast<wr_runtime *>(p)->cancelled.load();}
wr_runtime * wr_create(){return new wr_runtime();}
void wr_set_pause_callback(wr_runtime * r,wr_pause_predicate predicate,void * data) {
    if(r){r->should_pause=predicate;r->pause_data=data;}
}
// Keep one context/sampler alive across typing bursts. The 90-second work budget
// excludes time parked here; at most 30 cumulative minutes may retain a context.
struct GenerationBudget {
    using Clock=std::chrono::steady_clock;
    Clock::time_point active_deadline;
    Clock::duration paused{};
    Clock::duration pause_limit;
    wr_expiry_predicate expired=nullptr;
    void * expiry_data=nullptr;
    bool request_expired=false;
    bool check_expiry() {
        if(expired&&expired(expiry_data))request_expired=true;
        return request_expired;
    }
    GenerationBudget(Clock::duration active=std::chrono::seconds(90),Clock::duration limit=std::chrono::minutes(30))
        :active_deadline(Clock::now()+active),pause_limit(limit){}
};
static bool generation_ready(wr_runtime * r,GenerationBudget & budget) {
    using Clock=GenerationBudget::Clock;
    if(r->cancelled||budget.check_expiry()||Clock::now()>budget.active_deadline)return false;
    if(!r->should_pause||!r->should_pause(r->pause_data))return true;
    const auto start=Clock::now();
    const auto previous_phase=r->phase.exchange(4);
    bool ready=true;
    std::unique_lock<std::mutex> lock(r->pause_mutex);
    while(!r->cancelled&&r->should_pause(r->pause_data)) {
        if(budget.check_expiry()||budget.paused+Clock::now()-start>=budget.pause_limit){ready=false;break;}
        r->pause_changed.wait_for(lock,std::chrono::milliseconds(20),[r]{return r->cancelled.load();});
    }
    const auto elapsed=Clock::now()-start;
    budget.paused+=elapsed;budget.active_deadline+=elapsed;
    r->phase=previous_phase;
    return ready&&!r->cancelled&&!budget.check_expiry()&&budget.paused<budget.pause_limit&&Clock::now()<=budget.active_deadline;
}
int wr_load_attempt(wr_runtime * r,const char * library,const char * model,wr_load_ticket * ticket,wr_load_preflight preflight,void * data) {
    if(!r || !library || !model) return 1;
    if(wr_load_ticket_cancelled(ticket))return 5;
    ticket->phase=1;
    std::unique_lock<std::timed_mutex> lock(load_mutex,std::defer_lock);
    while(!lock.try_lock_for(std::chrono::milliseconds(5)))if(wr_load_ticket_cancelled(ticket))return 5;
    if(wr_load_ticket_cancelled(ticket))return 5;
    ticket->phase=2;
    if(preflight&&preflight(data)!=0)return 12;
    if(wr_load_ticket_cancelled(ticket))return 5;
    if(conflicting_images(library))return 11;
    if(wr_load_ticket_cancelled(ticket))return 5;
    r->cancelled=false;
    if(r->model) return 0;
    if(!r->lib) {
        ticket->phase=3;
        r->lib=dlopen(library,RTLD_NOW|RTLD_LOCAL); if(!r->lib) return 2;
        std::string directory(library);directory=directory.substr(0,directory.find_last_of('/'));
        if(!wr_dependencies_local(r,directory.c_str())) {r->lib=nullptr;return 11;}
        #define LOAD(name) r->name##_p=reinterpret_cast<decltype(&name)>(dlsym(r->lib,#name)); if(!r->name##_p) return 3;
        FUNCTIONS(LOAD)
        #undef LOAD
        r->llama_log_set_p(quiet,nullptr);
        // Runtime archive already links CPU/Metal backends. No backend discovery
        // from arbitrary directories and no RPC/backend service is started.
        r->llama_backend_init_p();
    }
    auto params=r->llama_model_default_params_p();
    params.n_gpu_layers=99;params.use_mmap=true;
    if(wr_load_ticket_cancelled(ticket))return 5;
    ticket->phase=4;
    params.progress_callback=[](float,void * p){return !wr_load_ticket_cancelled(static_cast<wr_load_ticket *>(p));};
    params.progress_callback_user_data=ticket;
    r->llama_log_set_p(load_evidence,r);
    r->model=r->llama_model_load_from_file_p(model,params);
    r->llama_log_set_p(quiet,nullptr);
    if(wr_load_ticket_cancelled(ticket)){wr_unload(r);return 5;}
    return r->model ? 0:4;
}
static int stopped_status(wr_runtime * r,const GenerationBudget & budget) {
    return !r->cancelled&&budget.request_expired ? 13:5;
}
static int generate(wr_runtime * r,const char * prompt,int max_tokens,char ** output,wr_expiry_predicate expired=nullptr,void * expiry_data=nullptr) {
    if(!r||!r->model||!prompt||!output||max_tokens<1||max_tokens>1024||strlen(prompt)>65536) return 1;
    *output=nullptr;if(r->cancelled) return 5;
    struct PhaseReset {wr_runtime * r;~PhaseReset(){r->phase=0;}} phase_reset{r};
    r->phase=1;
    GenerationBudget budget;budget.expired=expired;budget.expiry_data=expiry_data;
    if(!generation_ready(r,budget))return stopped_status(r,budget);
    auto vocab=r->llama_model_get_vocab_p(r->model);
    std::vector<llama_token> tokens(16384);
    int n=r->llama_tokenize_p(vocab,prompt,(int)strlen(prompt),tokens.data(),(int)tokens.size(),true,true);
    if(n<1||n+max_tokens>8192) return 6;
    auto params=r->llama_context_default_params_p();params.n_ctx=8192;params.n_batch=256;params.n_ubatch=256;
    params.n_seq_max=1;params.n_threads=4;params.n_threads_batch=4;params.abort_callback=abort_inference;params.abort_callback_data=r;
    if(!generation_ready(r,budget))return stopped_status(r,budget);
    auto ctx=r->llama_init_from_model_p(r->model,params);if(!ctx)return 7;
    auto sampler=r->llama_sampler_init_greedy_p();std::string text;int status=0;
    for(int pos=0;pos<n;pos+=256) {
        if(!generation_ready(r,budget)){status=stopped_status(r,budget);break;}
        auto batch=r->llama_batch_get_one_p(tokens.data()+pos,std::min(256,n-pos));
        r->phase=2;
        if(r->llama_decode_p(ctx,batch)!=0){status=8;break;}
        r->phase=1;
    }
    bool ended=false;
    for(int i=0;!status&&i<max_tokens;i++) {
        if(!generation_ready(r,budget)){status=stopped_status(r,budget);break;}
        r->phase=3;
        llama_token token=r->llama_sampler_sample_p(sampler,ctx,-1);
        if(r->llama_vocab_is_eog_p(vocab,token)){ended=true;break;}
        char piece[4096];int size=r->llama_token_to_piece_p(vocab,token,piece,sizeof(piece),0,true);
        if(size<0||text.size()+size>131072){status=9;break;}
        text.append(piece,size);
        if(!generation_ready(r,budget)){status=stopped_status(r,budget);break;}
        auto batch=r->llama_batch_get_one_p(&token,1);if(r->llama_decode_p(ctx,batch)!=0){status=8;break;}
    }
    if(!status&&(r->cancelled||budget.check_expiry()))status=stopped_status(r,budget);
    r->llama_sampler_free_p(sampler);r->llama_free_p(ctx);
    if(!status&&!ended)status=10;
    if(!status)*output=strdup(text.c_str());return status;
}
int wr_generate(wr_runtime * r,const char * prompt,int max_tokens,char ** output) {
    const int status=generate(r,prompt,max_tokens,output);
    if(r)r->generation_status=status;
    return status;
}
int wr_generate_until(wr_runtime * r,const char * prompt,int max_tokens,char ** output,wr_expiry_predicate expired,void * expiry_data) {
    const int status=generate(r,prompt,max_tokens,output,expired,expiry_data);
    if(r)r->generation_status=status;
    return status;
}
void wr_cancel(wr_runtime * r){if(r){r->cancelled=true;r->pause_changed.notify_all();}}
void wr_unload(wr_runtime * r){if(r&&r->model){r->llama_model_free_p(r->model);r->model=nullptr;}}
void wr_destroy(wr_runtime * r){if(r){wr_unload(r);/* keep loaded backend code process-wide for Metal callbacks */delete r;}}
void wr_release(char * p){free(p);}
int wr_offloaded_layers(wr_runtime * r){return r?r->offloaded:-1;}
int wr_total_layers(wr_runtime * r){return r?r->total:-1;}
int wr_execution_phase(wr_runtime * r){return r?r->phase.load():0;}
int wr_generation_status(wr_runtime * r){return r?r->generation_status.load():-1;}
int wr_dependencies_local(wr_runtime * r,const char * directory) {
    if(!r||!r->lib||!directory)return 0;
    const char * required[]={"libllama.0.dylib","libggml.0.dylib","libggml-base.0.dylib","libggml-cpu.0.dylib","libggml-metal.0.dylib","libggml-blas.0.dylib","libggml-rpc.0.dylib"};
    unsigned found=0;
    for(uint32_t i=0;i<_dyld_image_count();i++) {
        const char * name=_dyld_get_image_name(i);if(!name)continue;
        const char * base=strrchr(name,'/');base=base?base+1:name;
        for(unsigned j=0;j<7;j++) if(strcmp(base,required[j])==0) {
            char actual[PATH_MAX],expected[PATH_MAX];std::string target=std::string(directory)+"/"+required[j];
            if(!realpath(name,actual)||!realpath(target.c_str(),expected)||strcmp(actual,expected)!=0)return 0;
            found|=1u<<j;
        }
    }
    return found==127;
}
