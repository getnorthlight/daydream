import Foundation

public struct CloudConsent: Sendable {
    public let enabled: Bool
    /// The cloud notice the owner must accept (v2: typed words included; v3, fix/sx-all: page titles and email subjects
    /// named too). A switch saved under an older version never turns itself back on (WriterIntegration.resumeCloud).
    public static let currentVersion=3
    public let disclosureVersion: Int
    public init(enabled: Bool = false, disclosureVersion: Int = 0) { self.enabled=enabled;self.disclosureVersion=disclosureVersion }
    public static let disclosure = "Cloud summaries send what DayDream records, including page titles and the words you type when typing is on, through OpenRouter to write your notes. OpenRouter is told to use only model hosts that don't keep your data. OpenRouter keeps the time and cost of each request, and keeps the text only if logging is on in your OpenRouter account. Usage charges apply."
}
public struct CloudHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status=status;self.body=body }
}
/// Production integration must use an ephemeral, no-redirect, bounded HTTP sender.
/// This package does not automatically create a networking client or read credentials.
public typealias CloudSender = @Sendable (URLRequest) async throws -> CloudHTTPResponse
/// fix/sx-engine-battery: what OpenRouter's answer means for the person, typed so each has one fix
/// (SummaryProblem.cloudKey, .cloudCredits, .cloudHost, .cloudOffline).
public enum CloudFailure: Error, Equatable, Sendable {
    /// 401 or 403: the key was refused.
    case key
    /// 402: the account is out of credits.
    case credits
    /// 404, or a 400 about the data policy: no zero-retention host serves the model right now.
    case host
    /// 429, 5xx, a timeout or a dropped connection, still failing after the automatic retries.
    case offline
    /// The failure an HTTP status means; nil for 200 and for statuses retried automatically (429, 5xx).
    public static func from(status: Int, body: Data) -> CloudFailure? {
        switch status {
        case 200: return nil
        case 401, 403: return .key
        case 402: return .credits
        case 404: return .host
        case 400:
            let text = String(decoding: body.prefix(4096), as: UTF8.self).lowercased()
            return ["data policy", "data_policy", "zdr", "data_collection", "no endpoints", "retention"].contains(where: text.contains) ? .host : nil
        default: return nil
        }
    }
    /// Retried automatically before giving up: rate limits and server errors.
    static func retryable(_ status: Int) -> Bool { status == 429 || status == 408 || (500...599).contains(status) }
}
public struct CloudWriter: NoteWriter {
    public static let model = "deepseek/deepseek-v4-flash-0731"
    /// OpenRouter may answer with the model's alias slug (a dated or undated name of the same model).
    public static func sameModel(_ reply: String) -> Bool { reply.hasPrefix("deepseek/deepseek-v4-flash") }
    /// Waits between automatic retries of a 429, a 5xx, a timeout or an empty answer (checks shorten them).
    nonisolated(unsafe) public static var retryDelays: [TimeInterval] = [2, 8]
    private let consent: @Sendable () async -> CloudConsent
    private let key: @Sendable () async throws -> String
    private let policy: PolicyCheck
    private let send: CloudSender
    public init(consent: @escaping @Sendable () async -> CloudConsent, key: @escaping @Sendable () async throws -> String, policy: @escaping PolicyCheck, send: @escaping CloudSender) {
        self.consent=consent;self.key=key;self.policy=policy;self.send=send
    }
    public func write(_ batch: WriterBatch) async throws -> WriterNote {
        let data=try await complete(instruction:Grounding.instruction,evidence:Grounding.prompt(batch),permitted:{await policy(batch)})
        return try Grounding.validate(JSONDecoder().decode(ModelNote.self,from:data),batch:batch,provider:Self.model,zdr:true)
    }
    /// The connection was never made, so OpenRouter never saw (or billed) the request (gold/notes G26). A timeout, a
    /// dropped connection, a failed TLS handshake or any HTTP status is not here: the request may have been received.
    static let neverSent:Set<URLError.Code>=[.notConnectedToInternet,.cannotFindHost,.cannotConnectToHost,.dnsLookupFailed,.dataNotAllowed,.internationalRoamingOff]
    static func body(model: String = CloudWriter.model, maxTokens: Int, instruction: String, evidence: String) throws -> Data {
        try JSONSerialization.data(withJSONObject:[
            "model":model,"stream":false,"max_tokens":maxTokens,
            "provider":["zdr":true,"data_collection":"deny","allow_fallbacks":false,"require_parameters":true],
            // C7: the whole view is scrubbed again right before it leaves, defence in depth (typed words were scrubbed at capture).
            "messages":[["role":"system","content":instruction],["role":"user","content":CloudScrub.scrub(evidence)]]
        ])
    }
    static func request(secret: String, body: Data) -> URLRequest {
        var request=URLRequest(url:URL(string:"https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod="POST";request.timeoutInterval=30
        request.setValue("Bearer " + secret,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=body
        return request
    }
    /// A level note (blocks, days, weeks, months) through the same consent, key and checks as a moment note.
    public func completeText(instruction:String,evidence:String,maxTokens:Int,permitted:@Sendable () async -> Bool) async throws -> String {
        String(decoding:try await complete(instruction:instruction,evidence:evidence,maxTokens:maxTokens,permitted:permitted),as:UTF8.self)
    }
    /// fix/sx-engine-battery: 401/403, 402 and 404 (or a data-policy 400) end at once as `CloudFailure`; 429, 5xx, a
    /// timeout, a dropped connection and an empty or null answer are tried again after `retryDelays`, then end as
    /// `.offline` (or `notSent` when no attempt ever connected, `unavailable` for answers that stayed empty). Consent,
    /// the policy and the key are checked again before every attempt.
    func complete(instruction:String,evidence:String,maxTokens:Int=8192,permitted:@Sendable () async -> Bool) async throws -> Data {
        guard evidence.utf8.count<=24000,await consent().enabled, await consent().disclosureVersion == CloudConsent.currentVersion, await permitted() else { throw WriterFailure.denied }
        let body=try Self.body(maxTokens:maxTokens,instruction:instruction,evidence:evidence)
        let delays=Self.retryDelays
        var connected=false,emptyAnswers=0
        for attempt in 0...delays.count {
            if attempt > 0 { try await Task.sleep(nanoseconds:UInt64(max(0,delays[attempt-1])*1_000_000_000)) }
            let secret=try await key()
            guard !secret.isEmpty, !secret.contains("\r"), !secret.contains("\n") else { throw WriterFailure.unavailable }
            try Task.checkCancellation()
            guard await consent().enabled, await consent().disclosureVersion == CloudConsent.currentVersion, await permitted() else { throw WriterFailure.denied }
            let response: CloudHTTPResponse
            do { response=try await send(Self.request(secret:secret,body:body)) }
            catch let error as URLError where Self.neverSent.contains(error.code) { continue }
            catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch { connected=true; continue }
            connected=true
            if let failure=CloudFailure.from(status:response.status,body:response.body) { throw failure }
            if CloudFailure.retryable(response.status) { continue }
            guard response.status == 200, response.body.count <= 131072 else { throw WriterFailure.unavailable }
            struct Reply: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }; let model: String; let choices: [Choice]; let provider: String? }
            guard let reply=try? JSONDecoder().decode(Reply.self,from:response.body), Self.sameModel(reply.model), reply.choices.count == 1 else { throw WriterFailure.invalidOutput }
            // An empty or null answer (a host that stopped early) is tried again.
            guard let text=reply.choices.first?.message.content, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, let content=text.data(using:.utf8) else { emptyAnswers += 1; continue }
            // C8, record only: the model host OpenRouter names in the reply, if it names one. UNVERIFIED: the field name and the
            // list of zero-retention hosts need OpenRouter's docs, so no reply is refused on it and no copy relies on it.
            CloudProviderRecord.shared.record(reply.provider)
            guard await consent().enabled, await permitted() else { throw WriterFailure.denied }
            return content
        }
        if emptyAnswers > 0 { throw WriterFailure.unavailable }
        if !connected { throw WriterFailure.notSent }
        throw CloudFailure.offline
    }
    /// fix/sx-engine-battery: turning cloud summaries on tests the key with ONE tiny request: the same model and host
    /// rules as every note, one output token and a fixed prompt with nothing from the person's history. nil: accepted.
    public static let probeInstruction = "Reply with the word OK."
    public static func probe(key secret: String, send: CloudSender) async -> CloudFailure? {
        guard !secret.isEmpty, !secret.contains("\r"), !secret.contains("\n"),
              let body=try? body(maxTokens:1,instruction:probeInstruction,evidence:"OK?") else { return .key }
        do {
            let response=try await send(request(secret:secret,body:body))
            if let failure=CloudFailure.from(status:response.status,body:response.body) { return failure }
            return response.status == 200 ? nil : .offline
        } catch { return .offline }
    }
}

/// C8 (record only): the last model host OpenRouter named in a reply. Memory only; never shown as a retention promise.
public final class CloudProviderRecord: @unchecked Sendable {
    public static let shared=CloudProviderRecord()
    private let lock=NSLock();private var value:String?
    func record(_ provider:String?) {
        guard let provider,!provider.isEmpty,provider.utf8.count<=100 else {return}
        lock.lock();value=provider;lock.unlock()
    }
    public var last:String? {lock.lock();defer{lock.unlock()};return value}
}
/// C7: a last scrub of the whole cloud view (the WriterBackend side can't import MemoryCore's TypedSecretScrubber, so it
/// mirrors its strongest span rules): private keys, provider tokens, bearer headers, JWTs, card-like digit runs and
/// password/secret/token/key assignments become "[withheld]". Idempotent; text without secrets is returned unchanged.
public enum CloudScrub {
    static let marker="[withheld]"
    static let rules=[Pattern(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#),
                      Pattern(#"(?:sk-|sk_live_|ghp_|github_pat_|xox[bap]-|AKIA|AIza)[A-Za-z0-9_./+-]{6,}"#),
                      Pattern(#"(?i)\bBearer\s+[A-Za-z0-9_./+=-]{6,}"#),
                      Pattern(#"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*"#),
                      Pattern(#"(?<![0-9])(?:[0-9][ -]?){13,19}(?![0-9])"#),
                      Pattern(#"(?i)(?<=\b(?:password|passwd|pwd|secret|token|api[_-]?key)\s?[:=]\s?)[^\s"',;]{4,}"#)]
    public static func scrub(_ text:String)->String {
        var out=text
        for rule in rules {out=rule.replacing(out,with:marker)}
        return out
    }
}
