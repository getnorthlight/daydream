import Foundation

public struct ProductionSearchState:Codable,Equatable {
    public var phase:String
    public var advancedReason:String
    public var indexingLine:String?{phase=="indexing" ? "Indexing…" : nil}
    public var canShowResults:Bool{true}
}
/// Production binding over the caller's existing canonical store. Init/search
/// never start a process. begin is the explicit local launch lifecycle hook.
public final class ProductionSearchLaunch {
    private let store:MemoryStore
    private let lock=NSLock()
    private var worker:Process?,control:Pipe?
    private var begun=false,stopped=false
    private var state=ProductionSearchState(phase:"not_started",advancedReason:"local_runtime_setup_required")
    private var observer:((ProductionSearchState)->Void)?
    private var delivery=DispatchQueue.main
    public init(store:MemoryStore){self.store=store}
    public var snapshot:ProductionSearchState{lock.lock();defer{lock.unlock()};return state}
    @discardableResult public func begin(runtime:LocalSearchRuntime?,startupBudget:TimeInterval=8,callbackQueue:DispatchQueue = .main,onChange:@escaping(ProductionSearchState)->Void)->Bool {
        lock.lock();guard !begun else{lock.unlock();return false};begun=true;observer=onChange;delivery=callbackQueue;lock.unlock()
        guard let runtime else{publish("fallback","runtime_missing");return true}
        publish("checking","checking_private_local_runtime")
        let budget=startupBudget.isFinite ? max(0.05,min(20,startupBudget)) : 8
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+budget){[weak self] in
            guard let self,self.snapshot.phase=="checking" else{return}
            self.finish("fallback","startup_deadline_exceeded")
        }
        DispatchQueue.global(qos:.utility).async{[weak self] in
            guard let self else{return}
            do {
                try runtime.validate()
                let process=Process(),input=Pipe(),output=Pipe()
                process.executableURL=runtime.supervisor
                process.arguments=["search-supervise","--home",self.store.home.path,"--server",runtime.server.path,"--server-sha256",runtime.serverSHA256,"--startup-budget",String(budget)]
                process.environment=["PATH":"/usr/bin:/bin"]
                process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
                self.lock.lock()
                do {guard !self.stopped else{throw SearchFailure.unavailable};try process.run();self.worker=process;self.control=input;self.lock.unlock()}
                catch{self.lock.unlock();throw error}
                try? input.fileHandleForReading.close();try? output.fileHandleForWriting.close()
                // Reader does not retain the controller while waiting on a pipe.
                // Dropping the app binding closes control and stops the child.
                DispatchQueue.global(qos:.utility).async{[weak self] in
                    do {
                        var pending=Data()
                        while true {
                            let data=output.fileHandleForReading.availableData
                            if data.isEmpty{break};pending.append(data)
                            guard pending.count<=8192 else{throw SearchFailure.response}
                            while let newline=pending.firstIndex(of:10) {
                                let line=pending.prefix(upTo:newline);pending.removeSubrange(...newline)
                                let event=try JSONDecoder().decode(SearchWorkerEvent.self,from:line)
                                guard ["indexing","ready","fallback","stopped"].contains(event.phase) else{throw SearchFailure.response}
                                if event.phase=="fallback"{self?.finish("fallback",event.reason)}
                                else{self?.publish(event.phase,event.reason)}
                            }
                        }
                        self?.finish("fallback","supervisor_exited")
                    } catch {self?.finish("fallback","invalid_supervisor_response")}
                    process.waitUntilExit()
                    try? output.fileHandleForReading.close()
                    }
            } catch {if !self.isStopped{self.finish("fallback","runtime_or_supervisor_unavailable")}}
        }
        return true
    }
    private var isStopped:Bool{lock.lock();defer{lock.unlock()};return stopped}
    private func publish(_ phase:String,_ reason:String) {
        lock.lock();guard !stopped else{lock.unlock();return};state=ProductionSearchState(phase:phase,advancedReason:reason);let update=state;lock.unlock();notify(update)
    }
    private func notify(_ value:ProductionSearchState){
        lock.lock();let queue=delivery;lock.unlock()
        queue.async{[weak self] in
            guard let self else{return};self.lock.lock();let valid=self.state==value,callback=self.observer;self.lock.unlock()
            if valid{callback?(value)}
        }
    }
    private func finish(_ phase:String,_ reason:String){
        lock.lock();guard !stopped else{lock.unlock();return};stopped=true
        state=ProductionSearchState(phase:phase,advancedReason:reason);let update=state,pipe=control;control=nil;lock.unlock()
        try? pipe?.fileHandleForWriting.close();notify(update)
    }
    public func stop(){finish("stopped","stopped")}
    public func search(_ query:MemorySearchQuery,completion:@escaping(Result<MemorySearchResult,Error>)->Void){
        DispatchQueue.global(qos:.userInitiated).async{[self] in
            completion(Result {
                let current=snapshot
                if ["ready","indexing"].contains(current.phase){return try store.searchResult(query)}
                return try store.fallbackSearch(query,now:Date(),status:"unavailable_fallback")
            })
        }
    }
    deinit{try? control?.fileHandleForWriting.close()}
}
