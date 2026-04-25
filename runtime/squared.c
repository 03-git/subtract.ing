/*
 * squared — HTTP/2 cleartext proxy for local inference multiplexing
 *
 * Accepts h2c connections from browsers, proxies each stream to an
 * HTTP/1.1 backend (llama-server or any OpenAI-compatible endpoint).
 * Multiple prompts in flight on one connection, responses interleaved.
 *
 * Build: cc -o squared squared.c $(pkg-config --cflags --libs libnghttp2) -lpthread
 * Usage: squared [listen_port] [backend_host:port]
 *        squared 8090 127.0.0.1:8080
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

#define BUF_SIZE 16384
#define MAX_STREAMS 64

static char *backend_host = "127.0.0.1";
static char *backend_port = "8080";

typedef struct {
    int32_t stream_id;
    int backend_fd;
    char *req_path;
    char *req_method;
    char *req_body;
    size_t req_body_len;
    size_t req_body_cap;
    int headers_sent;
    char *resp_buf;
    size_t resp_len;
    size_t resp_cap;
    size_t resp_sent;
    int resp_complete;
    int resp_headers_done;
} stream_data;

typedef struct {
    nghttp2_session *session;
    int client_fd;
    stream_data streams[MAX_STREAMS];
    int nstreams;
} session_data;

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

static void free_stream(stream_data *s) {
    if (s->backend_fd >= 0) close(s->backend_fd);
    free(s->req_path);
    free(s->req_method);
    free(s->req_body);
    free(s->resp_buf);
    memset(s, 0, sizeof(*s));
    s->backend_fd = -1;
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

static char *extract_body(stream_data *s, size_t *body_len) {
    char *hdr_end = memmem(s->resp_buf, s->resp_len, "\r\n\r\n", 4);
    if (!hdr_end) { *body_len = 0; return NULL; }
    char *body = hdr_end + 4;
    *body_len = s->resp_len - (body - s->resp_buf);
    return body;
}

static ssize_t data_source_read(nghttp2_session *session,
    int32_t stream_id, uint8_t *buf, size_t length,
    uint32_t *data_flags, nghttp2_data_source *source,
    void *user_data)
{
    session_data *sd = user_data;
    stream_data *s = find_stream(sd, stream_id);
    if (!s) return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;

    size_t body_len;
    char *body = extract_body(s, &body_len);
    if (!body) {
        if (s->resp_complete) { *data_flags |= NGHTTP2_DATA_FLAG_EOF; return 0; }
        return NGHTTP2_ERR_DEFERRED;
    }

    size_t avail = body_len - s->resp_sent;
    if (avail == 0 && !s->resp_complete)
        return NGHTTP2_ERR_DEFERRED;

    size_t to_send = avail < length ? avail : length;
    memcpy(buf, body + s->resp_sent, to_send);
    s->resp_sent += to_send;

    if (s->resp_complete && s->resp_sent >= body_len)
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;

    return to_send;
}

static int on_begin_headers(nghttp2_session *session,
    const nghttp2_frame *frame, void *user_data)
{
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
    session_data *sd = user_data;
    if (frame->hd.type == NGHTTP2_HEADERS || frame->hd.type == NGHTTP2_DATA) {
        if (frame->hd.flags & NGHTTP2_FLAG_END_STREAM) {
            stream_data *s = find_stream(sd, frame->hd.stream_id);
            if (s) {
                send_backend_request(s);

                nghttp2_nv hdrs[] = {
                    {(uint8_t*)":status", (uint8_t*)"200", 7, 3,
                     NGHTTP2_NV_FLAG_NONE},
                    {(uint8_t*)"content-type",
                     (uint8_t*)"application/json", 12, 16,
                     NGHTTP2_NV_FLAG_NONE},
                    {(uint8_t*)"access-control-allow-origin",
                     (uint8_t*)"*", 27, 1, NGHTTP2_NV_FLAG_NONE},
                };

                nghttp2_data_provider prov;
                prov.source.ptr = s;
                prov.read_callback = data_source_read;

                nghttp2_submit_response(session, frame->hd.stream_id,
                    hdrs, 3, &prov);
            }
        }
    }
    return 0;
}

static int on_stream_close(nghttp2_session *session, int32_t stream_id,
    uint32_t error_code, void *user_data)
{
    session_data *sd = user_data;
    stream_data *s = find_stream(sd, stream_id);
    if (s) free_stream(s);
    return 0;
}

static ssize_t send_callback(nghttp2_session *session,
    const uint8_t *data, size_t length, int flags, void *user_data)
{
    session_data *sd = user_data;
    ssize_t n = write(sd->client_fd, data, length);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return NGHTTP2_ERR_WOULDBLOCK;
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    return n;
}

static void handle_client(int client_fd) {
    session_data sd = {0};
    sd.client_fd = client_fd;

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

        /* read backend data and resume deferred streams */
        for (int i = 1; i < nfds; i++) {
            if (fds[i].revents & POLLIN) {
                for (int j = 0; j < sd.nstreams; j++) {
                    if (sd.streams[j].backend_fd == fds[i].fd) {
                        read_backend(&sd.streams[j]);
                        nghttp2_session_resume_data(sd.session,
                            sd.streams[j].stream_id);
                        break;
                    }
                }
            }
        }

        /* read from h2 client */
        if (fds[0].revents & POLLIN) {
            uint8_t buf[BUF_SIZE];
            ssize_t n = read(client_fd, buf, sizeof(buf));
            if (n <= 0) break;
            ssize_t rv = nghttp2_session_mem_recv(sd.session, buf, n);
            if (rv < 0) break;
        }

        /* write h2 frames to client */
        if (nghttp2_session_want_write(sd.session)) {
            int rv = nghttp2_session_send(sd.session);
            if (rv != 0) break;
        }

        if (!nghttp2_session_want_read(sd.session) &&
            !nghttp2_session_want_write(sd.session))
            break;
    }

    nghttp2_session_del(sd.session);
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

    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);

    int listenfd = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(listenfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(listen_port);

    if (bind(listenfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }
    listen(listenfd, 16);

    fprintf(stderr, "squared listening on 127.0.0.1:%d -> %s:%s\n",
        listen_port, backend_host, backend_port);

    for (;;) {
        int fd = accept(listenfd, NULL, NULL);
        if (fd < 0) continue;
        int flag = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
        /* fork per connection — simple, correct, unix */
        pid_t pid = fork();
        if (pid == 0) {
            close(listenfd);
            handle_client(fd);
            _exit(0);
        }
        close(fd);
    }
}
