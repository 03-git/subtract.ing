/*
 * parsimony — inference as a unix filter
 *
 * Loads a GGUF once. Reads JSON requests from stdin (one per line).
 * Writes JSON responses to stdout (one per line). Stays alive.
 * The shell manages the lifecycle via coproc. Stateless: KV cache
 * clears between requests; the orchestrator owns conversation state.
 *
 * Wire format (input, one JSON line per request):
 *   {"messages":[{"role":"...","content":"..."},...],"max_tokens":N}
 *   OpenAI chat-completions-shaped. UTF-8 bytes, no \uXXXX escapes.
 *   No nested objects in content, no JSON inside JSON. Caller
 *   flattens with jq -c if needed (jq emits UTF-8 by default).
 *   Lines exceeding MAX_INPUT are drained and rejected.
 *
 * Wire format (output, one JSON line per response):
 *   {"choices":[{"message":{"role":"assistant","content":"..."},"finish_reason":"stop"}]}
 *
 * Build:
 *   cc -o parsimony parsimony.c -I/path/to/llama.cpp/include \
 *      -L/path/to/llama.cpp/lib -lllama -lggml -lm -lpthread
 *
 * Usage:
 *   coproc INF { ./parsimony model.gguf; }
 *   echo '{"messages":[{"role":"user","content":"hello"}]}' >&${INF[1]}
 *   read -r response <&${INF[0]}
 *
 *   # with standing context:
 *   coproc INF { ./parsimony model.gguf --prelude-file ~/subtract.ing/SOUL.txt; }
 */

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#include "ggml-backend.h"
#include "llama.h"

#define MAX_INPUT        65536
#define MAX_PROMPT_TOKENS 8192
#define DEFAULT_MAX_GEN   4096
#define MAX_RESPONSE     65536
#define MAX_ESCAPED     131072
#define MAX_MESSAGES        64

static struct message {
    char role[32];
    char content[8192];
} msgs_buf[MAX_MESSAGES];

static char prompt_buf[MAX_INPUT];
static char response_buf[MAX_RESPONSE];
static char escaped_buf[MAX_ESCAPED];

static const char *skip_to_value_quote(const char *p) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ':')
        p++;
    if (*p == '"') return p;
    return NULL;
}

static int parse_messages(const char *json, struct message *msgs, int max) {
    const char *p = strstr(json, "\"messages\"");
    if (!p) return 0;

    p = strchr(p, '[');
    if (!p) return 0;
    p++;

    int n = 0;
    while (n < max) {
        const char *obj = strchr(p, '{');
        if (!obj) break;

        const char *role = strstr(obj, "\"role\"");
        if (!role) break;
        role = skip_to_value_quote(role + 6);
        if (!role) break;
        role++;
        const char *role_end = strchr(role, '"');
        if (!role_end) break;
        int rlen = (int)(role_end - role);
        if (rlen >= 32) rlen = 31;
        memcpy(msgs[n].role, role, rlen);
        msgs[n].role[rlen] = '\0';

        const char *content = strstr(obj, "\"content\"");
        if (!content) break;
        content = skip_to_value_quote(content + 9);
        if (!content) break;
        content++;
        int ci = 0;
        while (*content && ci < 8191) {
            if (*content == '\\' && *(content + 1) == '"') {
                msgs[n].content[ci++] = '"';
                content += 2;
            } else if (*content == '\\' && *(content + 1) == 'n') {
                msgs[n].content[ci++] = '\n';
                content += 2;
            } else if (*content == '\\' && *(content + 1) == '\\') {
                msgs[n].content[ci++] = '\\';
                content += 2;
            } else if (*content == '\\' && *(content + 1) == 't') {
                msgs[n].content[ci++] = '\t';
                content += 2;
            } else if (*content == '\\' && *(content + 1) == 'r') {
                msgs[n].content[ci++] = '\r';
                content += 2;
            } else if (*content == '"') {
                break;
            } else {
                msgs[n].content[ci++] = *content++;
            }
        }
        msgs[n].content[ci] = '\0';

        n++;
        p = strchr(content, '}');
        if (!p) break;
        p++;
    }

    return n;
}

static int parse_int_field(const char *json, const char *field, int fallback) {
    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\"", field);
    const char *p = strstr(json, needle);
    if (!p) return fallback;
    p += strlen(needle);
    while (*p == ' ' || *p == ':') p++;
    long val = strtol(p, NULL, 10);
    if (val <= 0) return fallback;
    return (int)val;
}

static void json_escape(const char *src, char *dst, int max) {
    int i = 0;
    while (*src && i < max - 6) {
        switch (*src) {
        case '"':  dst[i++] = '\\'; dst[i++] = '"';  break;
        case '\\': dst[i++] = '\\'; dst[i++] = '\\'; break;
        case '\n': dst[i++] = '\\'; dst[i++] = 'n';  break;
        case '\r': dst[i++] = '\\'; dst[i++] = 'r';  break;
        case '\t': dst[i++] = '\\'; dst[i++] = 't';  break;
        default:   dst[i++] = *src; break;
        }
        src++;
    }
    dst[i] = '\0';
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s model.gguf [context_size] [threads] [--prelude-file path]\n", argv[0]);
        return 1;
    }

    signal(SIGPIPE, SIG_IGN);

    const char *model_path = argv[1];
    const char *prelude_path = NULL;
    int n_ctx = 4096;
    int n_threads = 4;
    bool ctx_set = false, threads_set = false;

    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--prelude-file") == 0 && i + 1 < argc) {
            prelude_path = argv[++i];
        } else if (!ctx_set && strtol(argv[i], NULL, 10) > 0) {
            n_ctx = (int)strtol(argv[i], NULL, 10);
            ctx_set = true;
        } else if (!threads_set && strtol(argv[i], NULL, 10) > 0) {
            n_threads = (int)strtol(argv[i], NULL, 10);
            threads_set = true;
        }
    }

    static char prelude_buf[MAX_INPUT];
    int prelude_len = 0;
    if (prelude_path) {
        FILE *pf = fopen(prelude_path, "r");
        if (!pf) {
            fprintf(stderr, "failed to read prelude: %s\n", prelude_path);
            return 1;
        }
        prelude_len = (int)fread(prelude_buf, 1, sizeof(prelude_buf) - 1, pf);
        fclose(pf);
        prelude_buf[prelude_len] = '\0';
        if (prelude_len == (int)(sizeof(prelude_buf) - 1))
            fprintf(stderr, "warning: prelude truncated at %d bytes\n", prelude_len);
    }

    llama_backend_init();
    ggml_backend_load_all();

    struct llama_model_params mp = llama_model_default_params();
    struct llama_model *model = llama_model_load_from_file(model_path, mp);
    if (!model) {
        fprintf(stderr, "failed to load: %s\n", model_path);
        return 1;
    }

    struct llama_context_params cp = llama_context_default_params();
    cp.n_ctx     = n_ctx;
    cp.n_batch   = 512;
    cp.n_threads = n_threads;
    struct llama_context *ctx = llama_init_from_model(model, cp);
    if (!ctx) {
        fprintf(stderr, "failed to create context\n");
        llama_model_free(model);
        return 1;
    }

    struct llama_sampler *smpl = llama_sampler_chain_init(
        llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    fprintf(stderr, "ready: %s (%d ctx, %d threads%s%s)\n",
            model_path, n_ctx, n_threads,
            prelude_path ? ", prelude=" : "",
            prelude_path ? prelude_path : "");
    fflush(stderr);

    char input[MAX_INPUT];

    while (fgets(input, sizeof(input), stdin)) {
        int len = (int)strlen(input);

        /* detect truncated line — drain remainder and reject */
        if (len > 0 && input[len - 1] != '\n') {
            int ch;
            while ((ch = fgetc(stdin)) != EOF && ch != '\n');
            fprintf(stderr, "request exceeded %d bytes, dropped\n", MAX_INPUT);
            printf("{\"error\":\"request too large\"}\n");
            fflush(stdout);
            continue;
        }

        if (len > 0 && input[len - 1] == '\n') input[--len] = '\0';
        if (len == 0) continue;

        int n_msgs = parse_messages(input, msgs_buf, MAX_MESSAGES);
        if (n_msgs == 0) {
            printf("{\"error\":\"no messages\"}\n");
            fflush(stdout);
            continue;
        }

        int max_gen = parse_int_field(input, "max_tokens", DEFAULT_MAX_GEN);

        struct llama_chat_message chat[MAX_MESSAGES + 1];
        int chat_n = 0;

        if (prelude_len > 0) {
            chat[chat_n].role    = "system";
            chat[chat_n].content = prelude_buf;
            chat_n++;
        }
        for (int i = 0; i < n_msgs && chat_n < MAX_MESSAGES + 1; i++) {
            chat[chat_n].role    = msgs_buf[i].role;
            chat[chat_n].content = msgs_buf[i].content;
            chat_n++;
        }

        int prompt_len = llama_chat_apply_template(
            NULL, chat, (size_t)chat_n, true,
            prompt_buf, sizeof(prompt_buf));
        if (prompt_len < 0 || prompt_len >= (int)sizeof(prompt_buf)) {
            printf("{\"error\":\"template failed\"}\n");
            fflush(stdout);
            continue;
        }
        prompt_buf[prompt_len] = '\0';

        const struct llama_vocab *vocab = llama_model_get_vocab(model);
        llama_token tokens[MAX_PROMPT_TOKENS];
        int n_tokens = llama_tokenize(
            vocab, prompt_buf, prompt_len,
            tokens, MAX_PROMPT_TOKENS, true, true);
        if (n_tokens < 0) {
            printf("{\"error\":\"tokenize failed (prompt too long)\"}\n");
            fflush(stdout);
            continue;
        }

        if (n_tokens >= n_ctx) {
            printf("{\"error\":\"prompt exceeds context\"}\n");
            fflush(stdout);
            continue;
        }
        if (max_gen > n_ctx - n_tokens)
            max_gen = n_ctx - n_tokens;

        llama_memory_clear(llama_get_memory(ctx), true);
        llama_sampler_reset(smpl);

        if (llama_decode(ctx, llama_batch_get_one(tokens, n_tokens)) < 0) {
            printf("{\"error\":\"decode failed\"}\n");
            fflush(stdout);
            continue;
        }

        int ri = 0;
        const char *finish = "stop";

        for (int i = 0; i < max_gen; i++) {
            llama_token id = llama_sampler_sample(smpl, ctx, -1);

            if (llama_vocab_is_eog(vocab, id)) break;

            char piece[256];
            int plen = llama_token_to_piece(
                vocab, id, piece, sizeof(piece), 0, true);
            if (plen > 0 && ri + plen < MAX_RESPONSE - 1) {
                memcpy(response_buf + ri, piece, plen);
                ri += plen;
            } else if (plen > 0) {
                finish = "length";
                break;
            }

            if (llama_decode(ctx, llama_batch_get_one(&id, 1)) < 0) {
                finish = "error";
                break;
            }
        }
        response_buf[ri] = '\0';

        json_escape(response_buf, escaped_buf, sizeof(escaped_buf));

        printf("{\"choices\":[{\"message\":{\"role\":\"assistant\","
               "\"content\":\"%s\"},\"finish_reason\":\"%s\"}]}\n",
               escaped_buf, finish);
        if (fflush(stdout) != 0) break;
    }

    llama_sampler_free(smpl);
    llama_free(ctx);
    llama_model_free(model);
    llama_backend_free();
    return 0;
}
