import Foundation

/// Exact text-only, no-tools, one system/user turn specialization of Qwen's
/// chat_template.jinja at 851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a,
/// with add_generation_prompt=true and enable_thinking=false. No general Jinja
/// interpreter, assistant history, vision, or tool-message path is accepted here.
public enum QwenNoThinkingTemplate {
    /// `prefill` opens the assistant turn (the local writer passes `{"title":"`); it is code, never evidence.
    public static func render(instruction:String,evidence:String,prefill:String="") throws -> String {
        guard instruction.utf8.count<=8192,evidence.utf8.count<=24000,prefill.utf8.count<=64,!prefill.contains("<") else {throw WriterFailure.invalidInput}
        let system=instruction.trimmingCharacters(in:.whitespacesAndNewlines)
        // Evidence is untrusted text (the writer's ITEMS view). Escape control-token
        // delimiters within it before applying the official template's trim/render path.
        let user=evidence.replacingOccurrences(of:"<",with:"\\u003c").trimmingCharacters(in:.whitespacesAndNewlines)
        return "<|im_start|>system\n"+system+"<|im_end|>\n<|im_start|>user\n"+user+"<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"+prefill
    }
}
