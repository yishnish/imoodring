import Foundation
import llama

// Synchronous, non-thread-safe wrapper around the llama.cpp C API.
// Always call from a single serial queue (GemmaMoodClassifier.inferenceQueue).
final class LlamaRunner {
    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private let contextLength: UInt32

    init(modelPath: String, nGpuLayers: Int32 = 9999, contextLength: UInt32 = 512) throws {
        print("[LlamaRunner] init start, path=\(modelPath)")
        llama_backend_init()
        print("[LlamaRunner] backend init done")

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = nGpuLayers

        print("[LlamaRunner] calling llama_model_load_from_file")
        guard let m = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaError.modelLoadFailed
        }
        print("[LlamaRunner] model loaded, calling llama_model_get_vocab")

        guard let v = llama_model_get_vocab(m) else {
            llama_model_free(m)
            throw LlamaError.modelLoadFailed
        }
        print("[LlamaRunner] vocab obtained: \(v)")

        self.model = m
        self.vocab = v
        self.contextLength = contextLength
        print("[LlamaRunner] init complete")
    }

    deinit {
        llama_model_free(model)
        llama_backend_free()
    }

    func generate(prompt: String, maxNewTokens: Int = 200) throws -> String {
        // Fresh context per call — clean KV cache without needing llama_kv_cache_clear.
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = contextLength
        ctxParams.n_batch = 512

        print("[LlamaRunner] init_from_model start")
        guard let ctx = llama_init_from_model(model, ctxParams) else {
            throw LlamaError.contextInitFailed
        }
        defer { llama_free(ctx) }
        print("[LlamaRunner] init_from_model done, tokenizing")

        let tokens = try tokenize(prompt)
        print("[LlamaRunner] tokenized: \(tokens.count) tokens")

        let sparams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(sparams) else {
            throw LlamaError.contextInitFailed
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        defer { llama_sampler_free(sampler) }

        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }

        batch.n_tokens = Int32(tokens.count)
        for (i, tok) in tokens.enumerated() {
            batch.token![i] = tok
            batch.pos![i] = Int32(i)
            batch.n_seq_id![i] = 1
            batch.seq_id![i]![0] = 0
            batch.logits![i] = i == tokens.count - 1 ? 1 : 0
        }
        guard llama_decode(ctx, batch) == 0 else { throw LlamaError.decodeFailed }

        let eosToken = llama_vocab_eos(vocab)
        let eotToken = llama_vocab_eot(vocab)
        var result = ""
        var nPos = tokens.count

        for _ in 0..<maxNewTokens {
            let next = llama_sampler_sample(sampler, ctx, -1)
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

            guard llama_decode(ctx, batch) == 0 else { break }
        }

        return result
    }

    // MARK: - Private

    private func tokenize(_ text: String) throws -> [llama_token] {
        let capacity = text.utf8.count + 64
        var buf = [llama_token](repeating: 0, count: capacity)
        print("[LlamaRunner] calling llama_tokenize, vocab=\(vocab), len=\(text.utf8.count)")
        let n = text.withCString { ptr in
            llama_tokenize(vocab, ptr, Int32(text.utf8.count), &buf, Int32(capacity), true, true)
        }
        print("[LlamaRunner] llama_tokenize returned \(n)")
        guard n > 0 else { throw LlamaError.tokenizationFailed }
        return Array(buf.prefix(Int(n)))
    }

    private func piece(for token: llama_token) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(vocab, token, &buf, 64, 0, false)
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
