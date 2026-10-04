// Synthetic bridge checks: no model library, keyboard/UI access, or owner data.
// Include the production bridge so these checks execute its real boundaries.
#include "../Sources/CLlamaBridge/WriterLlama.cpp"
#include <future>
#include <thread>
#include <iostream>
#include <stdexcept>

using namespace std::chrono_literals;
struct Fixture {
    wr_runtime runtime;
    std::atomic<bool> pause{false};
    std::atomic<int> tokenized{0},contexts{0},freed{0},decodes{0},samples{0},callbacks{0};
    std::vector<int> batches;
    int pause_after_decode=-1,pause_after_sample=-1;
    std::thread::id owner;
    int status=-1;
    std::string output;
};
static thread_local Fixture * current;
static int predicate(void * data) {
    auto f=static_cast<Fixture *>(data);
    if(std::this_thread::get_id()!=f->owner)throw std::runtime_error("predicate left serial generation thread");
    ++f->callbacks;return f->pause;
}
static void require(bool condition,const char * message) {
    if(!condition)throw std::runtime_error(message);
}
template<class Predicate> static void until(Predicate p) {
    const auto deadline=std::chrono::steady_clock::now()+2s;
    while(!p()){require(std::chrono::steady_clock::now()<deadline,"bounded fixture wait expired");std::this_thread::sleep_for(1ms);}
}
static void prepare(Fixture & f) {
    auto & r=f.runtime;
    r.model=reinterpret_cast<llama_model *>(&f);
    r.llama_model_get_vocab_p=[](const llama_model * model){return reinterpret_cast<const llama_vocab *>(model);};
    r.llama_tokenize_p=[](const llama_vocab *,const char *,int32_t,llama_token * tokens,int32_t,bool,bool)->int32_t {
        ++current->tokenized;for(int i=0;i<600;++i)tokens[i]=i;return 600;
    };
    r.llama_context_default_params_p=[](){return llama_context_params{};};
    r.llama_init_from_model_p=[](llama_model *,llama_context_params p){
        require(p.n_threads==4&&p.n_threads_batch==4,"inference thread pins changed");
        ++current->contexts;return reinterpret_cast<llama_context *>(current);
    };
    r.llama_sampler_init_greedy_p=[](){return reinterpret_cast<llama_sampler *>(current);};
    r.llama_batch_get_one_p=[](llama_token * tokens,int32_t n){llama_batch b{};b.n_tokens=n;b.token=tokens;return b;};
    r.llama_decode_p=[](llama_context * ctx,llama_batch b)->int32_t {
        require(ctx==reinterpret_cast<llama_context *>(current),"context restarted");
        current->batches.push_back(b.n_tokens);
        const int count=++current->decodes;
        if(count==current->pause_after_decode)current->pause=true;
        return 0;
    };
    r.llama_sampler_sample_p=[](llama_sampler *,llama_context *,int32_t)->llama_token {
        const int count=++current->samples;
        if(count==current->pause_after_sample)current->pause=true;
        return count<=3?count:99;
    };
    r.llama_vocab_is_eog_p=[](const llama_vocab *,llama_token token){return token==99;};
    r.llama_token_to_piece_p=[](const llama_vocab *,llama_token token,char * buffer,int32_t,int32_t,bool)->int32_t {buffer[0]='A'+token-1;return 1;};
    r.llama_sampler_free_p=[](llama_sampler *){};
    r.llama_free_p=[](llama_context *){++current->freed;};
}
static std::future<void> generate(Fixture & f) {
    prepare(f);
    return std::async(std::launch::async,[&f] {
        current=&f;f.owner=std::this_thread::get_id();
        wr_set_pause_callback(&f.runtime,predicate,&f);
        char * output=nullptr;
        f.status=wr_generate(&f.runtime,"synthetic",8,&output);
        if(output)f.output=output;
        wr_release(output);wr_set_pause_callback(&f.runtime,nullptr,nullptr);
    });
}
static void finish(std::future<void> & worker) {
    require(worker.wait_for(2s)==std::future_status::ready,"generation did not finish");worker.get();
}
static void successful(Fixture & f) {
    require(f.status==0&&f.output=="ABC","output changed across pause");
    require(f.contexts==1&&f.freed==1,"context was restarted or leaked");
    require(f.samples==4&&f.batches==std::vector<int>({256,256,88,1,1,1}),"token/prefill sequence changed");
    require(wr_execution_phase(&f.runtime)==0,"phase did not return to idle");
    require(wr_generation_status(&f.runtime)==0,"successful generation diagnostic missing");
}
int main() {
    try {
        {Fixture f;auto worker=generate(f);finish(worker);successful(f);std::cout<<"PASS unpaused output and runtime pins\n";}
        {Fixture f;f.pause=true;auto worker=generate(f);until([&]{return wr_execution_phase(&f.runtime)==4;});
            std::this_thread::sleep_for(50ms);require(f.tokenized==0&&f.contexts==0,"setup ran while paused");
            f.pause=false;finish(worker);successful(f);std::cout<<"PASS initial burst release without setup work\n";}
        {Fixture f;f.pause_after_decode=1;auto worker=generate(f);until([&]{return wr_execution_phase(&f.runtime)==4;});
            std::this_thread::sleep_for(60ms);require(f.decodes==1&&f.contexts==1&&f.freed==0,"prefill advanced/restarted while paused");
            f.pause=false;finish(worker);successful(f);std::cout<<"PASS prefill pause preserves context and sequence\n";}
        {Fixture f;f.pause_after_sample=1;auto worker=generate(f);until([&]{return wr_execution_phase(&f.runtime)==4;});
            std::this_thread::sleep_for(60ms);require(f.samples==1&&f.decodes==3,"token decode advanced while paused");
            f.pause=false;finish(worker);successful(f);std::cout<<"PASS sampled token pause preserves output\n";}
        {Fixture f;f.pause_after_decode=1;f.pause_after_sample=1;auto worker=generate(f);
            until([&]{return wr_execution_phase(&f.runtime)==4;});f.pause=false;
            until([&]{return f.samples==1&&wr_execution_phase(&f.runtime)==4;});
            require(f.contexts==1&&f.freed==0&&f.decodes==3,"repeated burst restarted generation");
            f.pause=false;finish(worker);successful(f);std::cout<<"PASS repeated bursts resume same generation\n";}
        {Fixture f;f.pause=true;wr_cancel(&f.runtime);auto worker=generate(f);finish(worker);
            require(f.status==5&&f.callbacks==0&&f.tokenized==0&&f.contexts==0,"queued cancellation entered pause/setup");
            std::cout<<"PASS queued cancellation skips pause and setup\n";}
        {Fixture f;f.pause_after_decode=1;auto worker=generate(f);until([&]{return wr_execution_phase(&f.runtime)==4;});
            const auto start=std::chrono::steady_clock::now();wr_cancel(&f.runtime);finish(worker);
            require(std::chrono::steady_clock::now()-start<500ms,"paused cancellation was not responsive");
            require(f.status==5&&wr_generation_status(&f.runtime)==5&&f.output.empty()&&f.decodes==1&&f.freed==1&&wr_execution_phase(&f.runtime)==0,"paused cancellation cleanup failed");
            std::cout<<"PASS paused cancellation cleans up retained context\n";}
        {Fixture f;f.owner=std::this_thread::get_id();wr_set_pause_callback(&f.runtime,predicate,&f);
            GenerationBudget budget(50ms,1s);f.pause=true;
            std::thread release([&]{std::this_thread::sleep_for(120ms);f.pause=false;});
            const bool ready=generation_ready(&f.runtime,budget);release.join();
            require(ready&&budget.paused>=120ms,"paused time consumed active deadline");
            std::this_thread::sleep_for(65ms);require(!generation_ready(&f.runtime,budget),"active work deadline no longer bounded");
            std::cout<<"PASS pause time excluded, active deadline retained\n";}
        {Fixture f;f.owner=std::this_thread::get_id();f.pause=true;wr_set_pause_callback(&f.runtime,predicate,&f);
            GenerationBudget budget(1s,60ms);const auto start=std::chrono::steady_clock::now();
            require(!generation_ready(&f.runtime,budget),"cumulative pause limit ignored");
            require(std::chrono::steady_clock::now()-start<500ms&&!f.runtime.cancelled&&wr_execution_phase(&f.runtime)==0,"pause-limit exit corrupted state");
            std::cout<<"PASS cumulative retained-context pause limit\n";}
        {wr_runtime r;char * output=nullptr;
            require(wr_generation_status(&r)==-1,"initial diagnostic was not unset");
            require(wr_generate(&r,"synthetic",8,&output)==1&&wr_generation_status(&r)==1,"early generation exit did not set diagnostic");
            std::cout<<"PASS value-free diagnostic covers early generation exits\n";}
        std::cout<<"10/10 pause checks passed; synthetic-only, no live typing/Metal claim\n";
    } catch(const std::exception & e) {std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
}
