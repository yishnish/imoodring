import Foundation
import llama

// Synchronous, non-thread-safe wrapper around the llama.cpp C API.
// Always call from a single serial queue (GemmaMoodClassifier.inferenceQueue).
final class LlamaRunner {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: OpaquePointer

    init(modelPath: String, nGpuLayers: Int32 = 9999, contextLength: UInt32 = 512) throws {
        llama_backend_init()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = nGpuLayers

        guard let m = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaError.modelLoadFailed
        }

        guard let v = llama_model_get_vocab(m) else {
            llama_model_free(m)
            throw LlamaError.modelLoadFailed
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = contextLength
        ctxParams.n_batch = 512

        guard let c = llama_init_from_model(m, ctxParams) else {
            llama_model_free(m)
            throw LlamaError.contextInitFailed
        }

        let sparams = llama_sampler_chain_default_params()
        let s = llama_sampler_chain_init(sparams)
        llama_sampler_chain_add(s, llama_sampler_init_greedy())

        model = m
        vocab = v
        context = c
        sampler = s
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(context)
        llama_model_free(model)
        llama_backend_free()
    }

    func generate(prompt: String, maxNewTokens: Int = 200) throws -> String {
        llama_kv_cache_clear(context)

        let tokens = try tokenize(prompt)

        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }

        // Prefill: feed prompt, enable logits only for the last token
        batch.n_tokens = Int32(tokens.count)
        for (i, tok) in tokens.enumerated() {
            batch.token![i] = tok
            batch.pos![i] = Int32(i)
            batch.n_seq_id![i] = 1
            batch.seq_id![i]![0] = 0
            batch.logits![i] = i == tokens.count - 1 ? 1 : 0
        }
        guard llama_decode(context, batch) == 0 else { throw LlamaError.decodeFailed }

        let eosToken = llama_vocab_eos(vocab)
        let eotToken = llama_vocab_eot(vocab)
        var result = ""
        var nPos = tokens.count

        for _ in 0..<maxNewTokens {
            let next = llama_sampler_sample(sampler, context, -1)
            if next == eosToken || next == eotToken { break }
            llama_sampler_accept(sampler, next)

            result += piece(for: next)

            batch.n_tokens = 1
            batch.token![0] = next
            batch.pos![0] = Int32(nPos)
            batch.n_seq_id![0] = 1
            batch.seq_id![0]![0] = 0
            batch.logits![0] = 1
            nPos += 1

            guard llama_decode(context, batch) == 0 else { break }
        }

        return result
    }

    // MARK: - Private

    private func tokenize(_ text: String) throws -> [llama_token] {
        let capacity = text.utf8.count + 64
        var buf = [llama_token](repeating: 0, count: capacity)
        let n = text.withCString { ptr in
            llama_tokenize(model, ptr, Int32(text.utf8.count), &buf, Int32(capacity), true, true)
        }
        guard n > 0 else { throw LlamaError.tokenizationFailed }
        return Array(buf.prefix(Int(n)))
    }

    private func piece(for token: llama_token) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(model, token, &buf, 64, 0, false)
        guard n > 0 else { return "" }
        return String(bytes: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
    }
}

enum LlamaError: Error {
    case modelLoadFailed
    case contextInitFailed
    case tokenizationFailed
    case decodeFailed
}
