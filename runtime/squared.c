/*
 * squared — HTTP/2 proxy for local inference multiplexing
 *
 * Without cert/key: h2c (cleartext HTTP/2, loopback only)
 * With cert/key:    h2 over TLS (ALPN negotiated, all interfaces)
 *
 * Build:
 *   cc -o squared squared.c $(pkg-config --cflags --libs libnghttp2) \
 *      -lmbedtls -lmbedx509 -lmbedcrypto -lpthread
 *
 * Usage:
 *   squared [port] [backend_host:port]
 *   squared [port] [backend_host:port] cert.pem key.pem
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <signal.h>
#include <poll.h>

#include <nghttp2/nghttp2.h>

#ifndef NO_TLS
#include <mbedtls/ssl.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/net_sockets.h>
#endif

#define BUF_SIZE 16384
#define MAX_STREAMS 64

#define CHUNK_SIZE_STATE  0
#define CHUNK_DATA_STATE  1
#define CHUNK_CRLF_STATE  2
#define CHUNK_DONE_STATE  3

static char *backend_host = "127.0.0.1";
static char *backend_port = "8080";

static int tls_mode = 0;
#ifndef NO_TLS
static mbedtls_ssl_config tls_conf;
static mbedtls_x509_crt tls_cert;
static mbedtls_pk_context tls_pkey;
static mbedtls_entropy_context tls_entropy;
static mbedtls_ctr_drbg_context tls_ctr_drbg;
static const char *tls_alpn[] = {"h2", NULL};
#endif

typedef struct {
    int32_t stream_id;
    int backend_fd;
    char *req_path;
    char *req_method;
    char *req_body;
    size_t req_body_len;
    size_t req_body_cap;
    int h2_submitted;
    char *resp_buf;
    size_t resp_len;
    size_t resp_cap;
    size_t resp_sent;
    int resp_complete;
    size_t resp_body_offset;
    char resp_content_type[128];
    char resp_status[4];
    int resp_chunked;
    int chunk_state;
    size_t chunk_remaining;
    size_t chunk_parse_offset;
    char *decoded_buf;
    size_t decoded_len;
    size_t decoded_cap;
    size_t decoded_sent;
} stream_data;

typedef struct {
    nghttp2_session *session;
    int client_fd;
#ifndef NO_TLS
    mbedtls_ssl_context *ssl;
#else
    void *ssl;
#endif
    stream_data streams[MAX_STREAMS];
    int nstreams;
} session_data;

#ifndef NO_TLS
static int tls_bio_send(void *ctx, const unsigned char *buf, size_t len) {
    int fd = *(int *)ctx;
    ssize_t n = write(fd, buf, len);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return MBEDTLS_ERR_SSL_WANT_WRITE;
        return MBEDTLS_ERR_NET_SEND_FAILED;
    }
    return (int)n;
}

static int tls_bio_recv(void *ctx, unsigned char *buf, size_t len) {
    int fd = *(int *)ctx;
    ssize_t n = read(fd, buf, len);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return MBEDTLS_ERR_SSL_WANT_READ;
        return MBEDTLS_ERR_NET_RECV_FAILED;
    }
    if (n == 0) return MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY;
    return (int)n;
}

static int init_tls(const char *cert_path, const char *key_path) {
    int ret;

    mbedtls_ssl_config_init(&tls_conf);
    mbedtls_x509_crt_init(&tls_cert);
    mbedtls_pk_init(&tls_pkey);
    mbedtls_entropy_init(&tls_entropy);
    mbedtls_ctr_drbg_init(&tls_ctr_drbg);

    ret = mbedtls_ctr_drbg_seed(&tls_ctr_drbg, mbedtls_entropy_func,
                                 &tls_entropy, NULL, 0);
    if (ret != 0) { fprintf(stderr, "ctr_drbg_seed: %d\n", ret); return -1; }

    ret = mbedtls_x509_crt_parse_file(&tls_cert, cert_path);
    if (ret != 0) { fprintf(stderr, "cert parse %s: %d\n", cert_path, ret); return -1; }

    ret = mbedtls_pk_parse_keyfile(&tls_pkey, key_path, NULL,
                                    mbedtls_ctr_drbg_random, &tls_ctr_drbg);
    if (ret != 0) { fprintf(stderr, "key parse %s: %d\n", key_path, ret); return -1; }

    ret = mbedtls_ssl_config_defaults(&tls_conf, MBEDTLS_SSL_IS_SERVER,
                                       MBEDTLS_SSL_TRANSPORT_STREAM,
                                       MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) { fprintf(stderr, "ssl config: %d\n", ret); return -1; }

    mbedtls_ssl_conf_rng(&tls_conf, mbedtls_ctr_drbg_random, &tls_ctr_drbg);
    mbedtls_ssl_conf_ca_chain(&tls_conf, tls_cert.next, NULL);

    ret = mbedtls_ssl_conf_own_cert(&tls_conf, &tls_cert, &tls_pkey);
    if (ret != 0) { fprintf(stderr, "own_cert: %d\n", ret); return -1; }

    ret = mbedtls_ssl_conf_alpn_protocols(&tls_conf, tls_alpn);
    if (ret != 0) { fprintf(stderr, "alpn: %d\n", ret); return -1; }

    tls_mode = 1;
    return 0;
}
#endif

static stream_data *find_stream(session_data *sd, int32_t stream_id) {
    for (int i = 0; i < sd->nstreams; i++)
        if (sd->streams[i].stream_id == stream_id) return &sd->streams[i];
    return NULL;
}

static stream_data *add_stream(session_data *sd, int32_t stream_id) {
    if (sd->nstreams >= MAX_STREAMS) return NULL;
    stream_data *s = &sd->streams[sd->nstreams++];
    memset(s, 0, sizeof(*s));
    s->stream_id = stream_id;
    s->backend_fd = -1;
    return s;
}

static void free_stream_data(stream_data *s) {
    if (s->backend_fd >= 0) close(s->backend_fd);
    free(s->req_path);
    free(s->req_method);
    free(s->req_body);
    free(s->resp_buf);
    free(s->decoded_buf);
}

static void remove_stream(session_data *sd, int32_t stream_id) {
    for (int i = 0; i < sd->nstreams; i++) {
        if (sd->streams[i].stream_id == stream_id) {
            free_stream_data(&sd->streams[i]);
            if (i < sd->nstreams - 1)
                sd->streams[i] = sd->streams[sd->nstreams - 1];
            sd->nstreams--;
            return;
        }
    }
}

static int connect_backend(void) {
    struct addrinfo hints = {0}, *res;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(backend_host, backend_port, &hints, &res) != 0) return -1;
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { freeaddrinfo(res); return -1; }
    if (connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
        close(fd);
        freeaddrinfo(res);
        return -1;
    }
    freeaddrinfo(res);
    int flag = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
    return fd;
}

static void send_backend_request(stream_data *s) {
    s->backend_fd = connect_backend();
    if (s->backend_fd < 0) {
        s->resp_complete = 1;
        return;
    }
    char header[4096];
    int n = snprintf(header, sizeof(header),
        "%s %s HTTP/1.1\r\n"
        "Host: %s:%s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n",
        s->req_method ? s->req_method : "POST",
        s->req_path ? s->req_path : "/",
        backend_host, backend_port,
        s->req_body_len);
    write(s->backend_fd, header, n);
    if (s->req_body && s->req_body_len > 0)
        write(s->backend_fd, s->req_body, s->req_body_len);
}

static void read_backend(stream_data *s) {
    char buf[BUF_SIZE];
    ssize_t n = read(s->backend_fd, buf, sizeof(buf));
    if (n <= 0) {
        s->resp_complete = 1;
        close(s->backend_fd);
        s->backend_fd = -1;
        return;
    }
    if (s->resp_len + n > s->resp_cap) {
        s->resp_cap = (s->resp_len + n) * 2;
        s->resp_buf = realloc(s->resp_buf, s->resp_cap);
    }
    memcpy(s->resp_buf + s->resp_len, buf, n);
    s->resp_len += n;
}

static int parse_backend_headers(stream_data *s) {
    if (s->resp_body_offset > 0) return 1;

    char *hdr_end = memmem(s->resp_buf, s->resp_len, "\r\n\r\n", 4);
    if (!hdr_end) return 0;

    s->resp_body_offset = (hdr_end + 4) - s->resp_buf;

    if (s->resp_len >= 12 && memcmp(s->resp_buf, "HTTP/1.", 7) == 0) {
        memcpy(s->resp_status, s->resp_buf + 9, 3);
        s->resp_status[3] = '\0';
    } else {
        strcpy(s->resp_status, "502");
    }

    strcpy(s->resp_content_type, "application/json");
    s->resp_chunked = 0;

    char *p = s->resp_buf;
    char *headers_end = s->resp_buf + s->resp_body_offset;
    while (p < headers_end) {
        char *eol = memmem(p, headers_end - p, "\r\n", 2);
        if (!eol) break;
        if (eol - p > 14 && strncasecmp(p, "content-type:", 13) == 0) {
            char *val = p + 13;
            while (val < eol && *val == ' ') val++;
            size_t vlen = eol - val;
            if (vlen >= sizeof(s->resp_content_type))
                vlen = sizeof(s->resp_content_type) - 1;
            memcpy(s->resp_content_type, val, vlen);
            s->resp_content_type[vlen] = '\0';
        }
        if (eol - p > 19 && strncasecmp(p, "transfer-encoding:", 18) == 0) {
            char *val = p + 18;
            while (val < eol && *val == ' ') val++;
            if (strncasecmp(val, "chunked", 7) == 0)
                s->resp_chunked = 1;
        }
        p = eol + 2;
    }

    s->chunk_state = CHUNK_SIZE_STATE;
    s->chunk_parse_offset = 0;

    return 1;
}

static void dechunk(stream_data *s) {
    if (!s->resp_chunked || s->resp_body_offset == 0) return;

    char *body = s->resp_buf + s->resp_body_offset;
    size_t body_len = s->resp_len - s->resp_body_offset;

    while (s->chunk_parse_offset < body_len &&
           s->chunk_state != CHUNK_DONE_STATE) {
        char *p = body + s->chunk_parse_offset;
        size_t remaining = body_len - s->chunk_parse_offset;

        if (s->chunk_state == CHUNK_SIZE_STATE) {
            char *eol = memmem(p, remaining, "\r\n", 2);
            if (!eol) return;
            s->chunk_remaining = strtoul(p, NULL, 16);
            s->chunk_parse_offset += (eol + 2 - p);
            if (s->chunk_remaining == 0)
                s->chunk_state = CHUNK_DONE_STATE;
            else
                s->chunk_state = CHUNK_DATA_STATE;

        } else if (s->chunk_state == CHUNK_DATA_STATE) {
            size_t avail = remaining < s->chunk_remaining
                         ? remaining : s->chunk_remaining;
            if (s->decoded_len + avail > s->decoded_cap) {
                s->decoded_cap = (s->decoded_len + avail) * 2;
                if (s->decoded_cap < 4096) s->decoded_cap = 4096;
                s->decoded_buf = realloc(s->decoded_buf, s->decoded_cap);
            }
            memcpy(s->decoded_buf + s->decoded_len, p, avail);
            s->decoded_len += avail;
            s->chunk_remaining -= avail;
            s->chunk_parse_offset += avail;
            if (s->chunk_remaining == 0)
                s->chunk_state = CHUNK_CRLF_STATE;

        } else if (s->chunk_state == CHUNK_CRLF_STATE) {
            if (remaining < 2) return;
            s->chunk_parse_offset += 2;
            s->chunk_state = CHUNK_SIZE_STATE;
        }
    }
}

static ssize_t data_source_read(nghttp2_session *session,
    int32_t stream_id, uint8_t *buf, size_t length,
    uint32_t *data_flags, nghttp2_data_source *source,
    void *user_data)
{
    session_data *sd = user_data;
    stream_data *s = find_stream(sd, stream_id);
    if (!s) return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;

    (void)session;
    (void)source;

    if (s->resp_body_offset == 0) {
        if (s->resp_complete) { *data_flags |= NGHTTP2_DATA_FLAG_EOF; return 0; }
        return NGHTTP2_ERR_DEFERRED;
    }

    if (s->resp_chunked) {
        size_t avail = s->decoded_len - s->decoded_sent;
        int done = s->resp_complete ||
                   s->chunk_state == CHUNK_DONE_STATE;
        if (avail == 0) {
            if (done) { *data_flags |= NGHTTP2_DATA_FLAG_EOF; return 0; }
            return NGHTTP2_ERR_DEFERRED;
        }
        size_t to_send = avail < length ? avail : length;
        memcpy(buf, s->decoded_buf + s->decoded_sent, to_send);
        s->decoded_sent += to_send;
        if (done && s->decoded_sent >= s->decoded_len)
            *data_flags |= NGHTTP2_DATA_FLAG_EOF;
        return to_send;
    }

    size_t body_len = s->resp_len - s->resp_body_offset;
    size_t avail = body_len - s->resp_sent;
    if (avail == 0 && !s->resp_complete)
        return NGHTTP2_ERR_DEFERRED;

    size_t to_send = avail < length ? avail : length;
    memcpy(buf, s->resp_buf + s->resp_body_offset + s->resp_sent, to_send);
    s->resp_sent += to_send;

    if (s->resp_complete && s->resp_sent >= body_len)
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;

    return to_send;
}

static void submit_h2_response(session_data *sd, stream_data *s) {
    if (s->h2_submitted) return;
    s->h2_submitted = 1;

    size_t ct_len = strlen(s->resp_content_type);
    size_t st_len = strlen(s->resp_status);

    nghttp2_nv hdrs[] = {
        {(uint8_t*)":status", (uint8_t*)s->resp_status, 7, st_len,
         NGHTTP2_NV_FLAG_NONE},
        {(uint8_t*)"content-type", (uint8_t*)s->resp_content_type,
         12, ct_len, NGHTTP2_NV_FLAG_NONE},
        {(uint8_t*)"access-control-allow-origin", (uint8_t*)"*",
         27, 1, NGHTTP2_NV_FLAG_NONE},
    };

    if (s->resp_complete && s->resp_len <= s->resp_body_offset) {
        nghttp2_submit_response(sd->session, s->stream_id, hdrs, 3, NULL);
    } else {
        nghttp2_data_provider prov;
        prov.source.ptr = s;
        prov.read_callback = data_source_read;
        nghttp2_submit_response(sd->session, s->stream_id, hdrs, 3, &prov);
    }
}

static void submit_cors_preflight(session_data *sd, int32_t stream_id) {
    nghttp2_nv hdrs[] = {
        {(uint8_t*)":status", (uint8_t*)"204", 7, 3,
         NGHTTP2_NV_FLAG_NONE},
        {(uint8_t*)"access-control-allow-origin", (uint8_t*)"*",
         27, 1, NGHTTP2_NV_FLAG_NONE},
        {(uint8_t*)"access-control-allow-methods",
         (uint8_t*)"GET, POST, OPTIONS", 28, 18,
         NGHTTP2_NV_FLAG_NONE},
        {(uint8_t*)"access-control-allow-headers",
         (uint8_t*)"content-type, authorization", 28, 27,
         NGHTTP2_NV_FLAG_NONE},
        {(uint8_t*)"access-control-max-age", (uint8_t*)"86400",
         22, 5, NGHTTP2_NV_FLAG_NONE},
    };
    nghttp2_submit_response(sd->session, stream_id, hdrs, 5, NULL);
}

static int on_begin_headers(nghttp2_session *session,
    const nghttp2_frame *frame, void *user_data)
{
    (void)session;
    session_data *sd = user_data;
    if (frame->hd.type == NGHTTP2_HEADERS &&
        frame->headers.cat == NGHTTP2_HCAT_REQUEST)
        add_stream(sd, frame->hd.stream_id);
    return 0;
}

static int on_header(nghttp2_session *session, const nghttp2_frame *frame,
    const uint8_t *name, size_t namelen,
    const uint8_t *value, size_t valuelen,
    uint8_t flags, void *user_data)
{
    (void)session;
    (void)flags;
    session_data *sd = user_data;
    stream_data *s = find_stream(sd, frame->hd.stream_id);
    if (!s) return 0;
    if (namelen == 5 && memcmp(name, ":path", 5) == 0)
        s->req_path = strndup((char*)value, valuelen);
    else if (namelen == 7 && memcmp(name, ":method", 7) == 0)
        s->req_method = strndup((char*)value, valuelen);
    return 0;
}

static int on_data_chunk(nghttp2_session *session, uint8_t flags,
    int32_t stream_id, const uint8_t *data, size_t len, void *user_data)
{
    (void)session;
    (void)flags;
    session_data *sd = user_data;
    stream_data *s = find_stream(sd, stream_id);
    if (!s) return 0;
    if (s->req_body_len + len > s->req_body_cap) {
        s->req_body_cap = (s->req_body_len + len) * 2;
        if (s->req_body_cap < 4096) s->req_body_cap = 4096;
        s->req_body = realloc(s->req_body, s->req_body_cap);
    }
    memcpy(s->req_body + s->req_body_len, data, len);
    s->req_body_len += len;
    return 0;
}

static int on_frame_recv(nghttp2_session *session,
    const nghttp2_frame *frame, void *user_data)
{
    (void)session;
    session_data *sd = user_data;
    if (frame->hd.type == NGHTTP2_HEADERS || frame->hd.type == NGHTTP2_DATA) {
        if (frame->hd.flags & NGHTTP2_FLAG_END_STREAM) {
            stream_data *s = find_stream(sd, frame->hd.stream_id);
            if (s) {
                if (s->req_method && strcmp(s->req_method, "OPTIONS") == 0) {
                    submit_cors_preflight(sd, frame->hd.stream_id);
                    return 0;
                }
                send_backend_request(s);
            }
        }
    }
    return 0;
}

static int on_stream_close(nghttp2_session *session, int32_t stream_id,
    uint32_t error_code, void *user_data)
{
    (void)session;
    (void)error_code;
    session_data *sd = user_data;
    remove_stream(sd, stream_id);
    return 0;
}

static ssize_t send_callback(nghttp2_session *session,
    const uint8_t *data, size_t length, int flags, void *user_data)
{
    (void)session;
    (void)flags;
    session_data *sd = user_data;

#ifndef NO_TLS
    if (sd->ssl) {
        int n = mbedtls_ssl_write(sd->ssl, data, length);
        if (n == MBEDTLS_ERR_SSL_WANT_WRITE) return NGHTTP2_ERR_WOULDBLOCK;
        if (n < 0) return NGHTTP2_ERR_CALLBACK_FAILURE;
        return n;
    }
#endif

    ssize_t n = write(sd->client_fd, data, length);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return NGHTTP2_ERR_WOULDBLOCK;
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    return n;
}

#ifndef NO_TLS
static void handle_client(int client_fd, mbedtls_ssl_context *ssl) {
#else
static void handle_client(int client_fd, void *ssl) {
#endif
    session_data sd = {0};
    sd.client_fd = client_fd;
    sd.ssl = ssl;

    nghttp2_session_callbacks *cb;
    nghttp2_session_callbacks_new(&cb);
    nghttp2_session_callbacks_set_send_callback(cb, send_callback);
    nghttp2_session_callbacks_set_on_begin_headers_callback(cb, on_begin_headers);
    nghttp2_session_callbacks_set_on_header_callback(cb, on_header);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cb, on_data_chunk);
    nghttp2_session_callbacks_set_on_frame_recv_callback(cb, on_frame_recv);
    nghttp2_session_callbacks_set_on_stream_close_callback(cb, on_stream_close);

    nghttp2_session_server_new(&sd.session, cb, &sd);
    nghttp2_session_callbacks_del(cb);

    nghttp2_settings_entry iv = {NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, MAX_STREAMS};
    nghttp2_submit_settings(sd.session, NGHTTP2_FLAG_NONE, &iv, 1);

    for (;;) {
        struct pollfd fds[MAX_STREAMS + 1];
        int nfds = 0;

        fds[nfds].fd = client_fd;
        fds[nfds].events = POLLIN;
        if (nghttp2_session_want_write(sd.session))
            fds[nfds].events |= POLLOUT;
        nfds++;

        for (int i = 0; i < sd.nstreams; i++) {
            if (sd.streams[i].backend_fd >= 0 && !sd.streams[i].resp_complete) {
                fds[nfds].fd = sd.streams[i].backend_fd;
                fds[nfds].events = POLLIN;
                nfds++;
            }
        }

        int ret = poll(fds, nfds, 100);
        if (ret < 0) break;

        for (int i = 1; i < nfds; i++) {
            if (fds[i].revents & POLLIN) {
                for (int j = 0; j < sd.nstreams; j++) {
                    if (sd.streams[j].backend_fd == fds[i].fd) {
                        read_backend(&sd.streams[j]);
                        if (!sd.streams[j].h2_submitted &&
                            parse_backend_headers(&sd.streams[j]))
                            submit_h2_response(&sd, &sd.streams[j]);
                        if (sd.streams[j].resp_chunked)
                            dechunk(&sd.streams[j]);
                        nghttp2_session_resume_data(sd.session,
                            sd.streams[j].stream_id);
                        break;
                    }
                }
            }
        }

        if (fds[0].revents & POLLIN) {
            uint8_t buf[BUF_SIZE];
            ssize_t n;
#ifndef NO_TLS
            if (sd.ssl) {
                n = mbedtls_ssl_read(sd.ssl, buf, sizeof(buf));
                if (n == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY || n == 0) break;
                if (n < 0) break;
            } else
#endif
            {
                n = read(client_fd, buf, sizeof(buf));
                if (n <= 0) break;
            }
            ssize_t rv = nghttp2_session_mem_recv(sd.session, buf, n);
            if (rv < 0) break;
        }

        for (int i = 0; i < sd.nstreams; i++) {
            if (!sd.streams[i].h2_submitted && sd.streams[i].resp_complete) {
                strcpy(sd.streams[i].resp_status, "502");
                strcpy(sd.streams[i].resp_content_type, "text/plain");
                sd.streams[i].resp_body_offset = sd.streams[i].resp_len;
                submit_h2_response(&sd, &sd.streams[i]);
            }
        }

        if (nghttp2_session_want_write(sd.session)) {
            int rv = nghttp2_session_send(sd.session);
            if (rv != 0) break;
        }

        if (!nghttp2_session_want_read(sd.session) &&
            !nghttp2_session_want_write(sd.session))
            break;
    }

    nghttp2_session_del(sd.session);

#ifndef NO_TLS
    if (ssl) {
        mbedtls_ssl_close_notify(ssl);
        mbedtls_ssl_free(ssl);
    }
#endif

    close(client_fd);
}

int main(int argc, char **argv) {
    int listen_port = 8090;

    if (argc >= 2) listen_port = atoi(argv[1]);
    if (argc >= 3) {
        char *colon = strrchr(argv[2], ':');
        if (colon) {
            *colon = '\0';
            backend_host = argv[2];
            backend_port = colon + 1;
        }
    }
#ifndef NO_TLS
    if (argc >= 5) {
        if (init_tls(argv[3], argv[4]) != 0) {
            fprintf(stderr, "TLS init failed\n");
            return 1;
        }
    }
#endif

    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);

    int listenfd = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(listenfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = tls_mode ? htonl(INADDR_ANY) : htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(listen_port);

    if (bind(listenfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }
    listen(listenfd, 16);

    fprintf(stderr, "squared listening on %s:%d -> %s:%s%s\n",
        tls_mode ? "0.0.0.0" : "127.0.0.1",
        listen_port, backend_host, backend_port,
        tls_mode ? " (tls)" : " (h2c)");

    for (;;) {
        int fd = accept(listenfd, NULL, NULL);
        if (fd < 0) continue;
        int flag = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));

        pid_t pid = fork();
        if (pid == 0) {
            close(listenfd);

#ifndef NO_TLS
            if (tls_mode) {
                mbedtls_ssl_context ssl;
                mbedtls_ssl_init(&ssl);
                if (mbedtls_ssl_setup(&ssl, &tls_conf) != 0) _exit(1);
                mbedtls_ssl_set_bio(&ssl, &fd, tls_bio_send, tls_bio_recv, NULL);

                int ret = mbedtls_ssl_handshake(&ssl);
                if (ret != 0) {
                    mbedtls_ssl_free(&ssl);
                    close(fd);
                    _exit(1);
                }

                const char *proto = mbedtls_ssl_get_alpn_protocol(&ssl);
                if (!proto || strcmp(proto, "h2") != 0) {
                    mbedtls_ssl_close_notify(&ssl);
                    mbedtls_ssl_free(&ssl);
                    close(fd);
                    _exit(1);
                }

                handle_client(fd, &ssl);
            } else
#endif
            {
                handle_client(fd, NULL);
            }

            _exit(0);
        }
        close(fd);
    }
}
