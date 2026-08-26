/*
 * claude-dashboard-proxy: Transparent PTY proxy for agent state detection.
 * Usage: claude-dashboard-proxy <command> [args...]
 *
 * Spawns <command> in a PTY, forwards I/O transparently,
 * detects agent state from terminal output patterns,
 * and writes to /tmp/claude-dash/<pid>.state
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <termios.h>
#include <util.h>
#include <time.h>
#include <sys/stat.h>
#include <ctype.h>

#define STATE_DIR "/tmp/claude-dash"
#define RING_SIZE 8192
#define TITLE_SIZE 256
#define CLEAN_SIZE 4096
#define CHECK_INTERVAL_MS 200
#define DEBOUNCE_COUNT 4  /* confirmations needed for working→idle (4*200ms=800ms) */

static int master_fd = -1;
static pid_t child_pid = 0;
static struct termios orig_termios;
static int raw_mode_set = 0;

/* Ring buffer for recent output (raw bytes) */
static char ring[RING_SIZE];
static int ring_pos = 0;
static int ring_len = 0;

/* OSC title buffer */
static char osc_title[TITLE_SIZE];
static int osc_collecting = 0;
static int osc_pos = 0;
static int osc_st_pending = 0; /* waiting for \ after ESC in ST terminator */

/* State tracking */
typedef enum { ST_IDLE, ST_WORKING, ST_NEEDS_INPUT } state_t;
static state_t current_state = ST_IDLE;
static const char *agent_type = NULL; /* "claude" or "codex" */

/* Debounce: hold working→idle until confirmed N times */
static int idle_confirmations = 0;
static int did_chat_intro = 0;

static void cleanup(void) {
    if (raw_mode_set) {
        tcsetattr(STDIN_FILENO, TCSANOW, &orig_termios);
        raw_mode_set = 0;
    }
}

/* Remove state file on exit */
static void cleanup_state(void) {
    if (child_pid > 0) {
        char path[128];
        snprintf(path, sizeof(path), STATE_DIR "/%d.state", child_pid);
        unlink(path);
    }
}

static void sigchld_handler(int sig) { (void)sig; }

static void sigwinch_handler(int sig) {
    (void)sig;
    if (master_fd >= 0) {
        struct winsize ws;
        if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0)
            ioctl(master_fd, TIOCSWINSZ, &ws);
    }
}

static void sigterm_handler(int sig) {
    if (child_pid > 0) kill(child_pid, sig);
}

static void sigint_handler(int sig) {
    if (child_pid > 0) kill(child_pid, sig);
}

/* Get the real TTY name (the terminal tab's TTY, not the slave PTY) */
static char real_tty[64] = "";
static void init_real_tty(void) {
    char *t = ttyname(STDIN_FILENO);
    if (t) {
        const char *name = t;
        if (strncmp(name, "/dev/", 5) == 0) name += 5;
        snprintf(real_tty, sizeof(real_tty), "%s", name);
    }
}

/* Write state file — includes real TTY for terminal reveal */
static char session_name[128] = "";
static char session_project[128] = "";

static void init_session_info(void) {
    const char *n = getenv("CDASH_SESSION_NAME");
    if (n) snprintf(session_name, sizeof(session_name), "%s", n);
    const char *p = getenv("CDASH_PROJECT");
    if (p) snprintf(session_project, sizeof(session_project), "%s", p);
}

static void write_state(pid_t pid, state_t state) {
    mkdir(STATE_DIR, 0755);
    char path[128];
    snprintf(path, sizeof(path), STATE_DIR "/%d.state", pid);
    const char *event;
    switch (state) {
        case ST_WORKING: event = "working"; break;
        case ST_NEEDS_INPUT: event = "needs_input"; break;
        default: event = "stop"; break;
    }
    char tmp[256];
    snprintf(tmp, sizeof(tmp), STATE_DIR "/%d.state.tmp", pid);
    FILE *f = fopen(tmp, "w");
    if (f) {
        fprintf(f, "{\"event\":\"%s\",\"ts\":%ld,\"tty\":\"%s\",\"proxy_pid\":%d,\"name\":\"%s\",\"project\":\"%s\"}",
                event, (long)time(NULL), real_tty, (int)getpid(), session_name, session_project);
        fclose(f);
        rename(tmp, path);
    }
}

/* Ring buffer: append data */
static void ring_append(const char *data, int len) {
    for (int i = 0; i < len; i++) {
        ring[ring_pos] = data[i];
        ring_pos = (ring_pos + 1) % RING_SIZE;
        if (ring_len < RING_SIZE) ring_len++;
    }
}

/* Ring buffer: get recent content, stripping ANSI escapes.
   Only examines last 4KB so screen redraws push out stale content. */
static int ring_recent_clean(char *out, int max) {
    int avail = ring_len < RING_SIZE ? ring_len : RING_SIZE;
    if (avail > 4096) avail = 4096; /* ~1 render cycle */
    if (avail <= 0) { out[0] = '\0'; return 0; }
    char raw[RING_SIZE + 1];
    int start = (ring_pos - avail + RING_SIZE) % RING_SIZE;
    for (int i = 0; i < avail; i++)
        raw[i] = ring[(start + i) % RING_SIZE];
    raw[avail] = '\0';

    /* Strip ANSI escape sequences, inserting space to preserve word boundaries */
    int j = 0;
    for (int i = 0; i < avail && j < max - 1; i++) {
        unsigned char c = (unsigned char)raw[i];
        if (c == 0x1b) {
            if (i + 1 < avail && raw[i + 1] == '[') {
                /* CSI sequence: skip until letter, emit space */
                i += 2;
                while (i < avail && !((raw[i] >= 'A' && raw[i] <= 'Z') ||
                       (raw[i] >= 'a' && raw[i] <= 'z'))) i++;
                if (j > 0 && out[j-1] != ' ' && out[j-1] != '\n')
                    out[j++] = ' ';
                continue;
            }
            if (i + 1 < avail && raw[i + 1] == ']') {
                /* OSC sequence: skip until BEL or ST */
                i += 2;
                while (i < avail && raw[i] != 0x07) {
                    if (raw[i] == 0x1b && i + 1 < avail && raw[i + 1] == '\\') {
                        i++; break;
                    }
                    i++;
                }
                if (j > 0 && out[j-1] != ' ' && out[j-1] != '\n')
                    out[j++] = ' ';
                continue;
            }
            /* Other escape: skip ESC + next char */
            i++;
            continue;
        }
        /* Skip control chars except newline/tab */
        if (c < 0x20 && c != '\n' && c != '\t') continue;
        out[j++] = raw[i];
    }
    out[j] = '\0';
    return j;
}

/* OSC title tracking: handles both BEL (\x07) and ST (\x1b\\) terminators */
static void track_osc(const char *data, int len) {
    for (int i = 0; i < len; i++) {
        unsigned char c = (unsigned char)data[i];

        /* Handle pending ST: ESC was seen, check for \ */
        if (osc_st_pending) {
            osc_st_pending = 0;
            if (c == '\\' && osc_collecting) {
                osc_title[osc_pos] = '\0';
                osc_collecting = 0;
                osc_pos = 0;
            }
            continue;
        }

        if (osc_collecting) {
            if (c == 0x07) { /* BEL terminates OSC */
                osc_title[osc_pos] = '\0';
                osc_collecting = 0;
                osc_pos = 0;
            } else if (c == 0x1b) { /* ESC — might be start of ST (\x1b\\) */
                osc_st_pending = 1;
            } else if (osc_pos < TITLE_SIZE - 1) {
                osc_title[osc_pos++] = c;
            }
        } else if (c == 0x1b && i + 1 < len && data[i + 1] == ']') {
            i++; /* skip ] */
            if (i + 1 < len && (data[i + 1] == '0' || data[i + 1] == '2') &&
                i + 2 < len && data[i + 2] == ';') {
                i += 2; /* skip N; */
                osc_collecting = 1;
                osc_pos = 0;
            }
        }
    }
}

/* Check if string contains a substring (case insensitive) */
static int contains_ci(const char *haystack, const char *needle) {
    if (!haystack || !needle) return 0;
    size_t hlen = strlen(haystack), nlen = strlen(needle);
    if (nlen > hlen) return 0;
    for (size_t i = 0; i <= hlen - nlen; i++) {
        int match = 1;
        for (size_t j = 0; j < nlen; j++) {
            if (tolower((unsigned char)haystack[i + j]) != tolower((unsigned char)needle[j])) {
                match = 0; break;
            }
        }
        if (match) return 1;
    }
    return 0;
}

/* Check if title contains braille spinner characters (U+2800-U+28FF) */
static int title_has_braille(const char *title) {
    const unsigned char *p = (const unsigned char *)title;
    while (*p) {
        /* UTF-8 braille: E2 A0 80 to E2 A3 BF — check bounds before accessing p[1], p[2] */
        if (p[0] == 0xE2) {
            if (p[1] == 0) break;
            if (p[1] >= 0xA0 && p[1] <= 0xA3) {
                if (p[2] == 0) break;
                if (p[2] >= 0x80 && p[2] <= 0xBF) return 1;
            }
            p += 3;
        } else if (*p >= 0x80) {
            if ((*p & 0xE0) == 0xC0) { if (!p[1]) break; p += 2; }
            else if ((*p & 0xF0) == 0xE0) { if (!p[1] || !p[2]) break; p += 3; }
            else if ((*p & 0xF8) == 0xF0) { if (!p[1] || !p[2] || !p[3]) break; p += 4; }
            else p++;
        } else {
            p++;
        }
    }
    return 0;
}

/* Check if title starts with ✳ (U+2733, UTF-8: E2 9C B3) */
static int title_starts_with_sparkle(const char *title) {
    const unsigned char *p = (const unsigned char *)title;
    if (p[0] == 0 || p[1] == 0 || p[2] == 0) return 0;
    return p[0] == 0xE2 && p[1] == 0x9C && p[2] == 0xB3;
}

/* Detect state from screen content and OSC title */
static state_t detect_state(const char *screen, const char *title) {
    if (!agent_type) return ST_IDLE;

    if (strcmp(agent_type, "claude") == 0) {
        /* Screen checks first — needs_input overrides title spinner */
        if (contains_ci(screen, "do you want to proceed?") &&
            (contains_ci(screen, "yes") || strstr(screen, "\xe2\x9d\xaf") /* ❯ */))
            return ST_NEEDS_INPUT;
        if (contains_ci(screen, "esc to cancel") &&
            (contains_ci(screen, "enter to confirm") || contains_ci(screen, "enter to select")))
            return ST_NEEDS_INPUT;
        /* OSC title: braille spinner = working */
        if (title_has_braille(title)) return ST_WORKING;
        /* OSC title: ✳ = idle */
        if (title_starts_with_sparkle(title)) return ST_IDLE;
    } else if (strcmp(agent_type, "codex") == 0) {
        /* OSC title: "Action Required" = blocked */
        if (contains_ci(title, "Action Required")) return ST_NEEDS_INPUT;
        /* OSC title: spinner = working */
        if (title_has_braille(title)) return ST_WORKING;
        /* Screen: working indicator */
        if (contains_ci(screen, "working") && contains_ci(screen, "esc to interrupt"))
            return ST_WORKING;
        /* Permission prompts */
        if (contains_ci(screen, "allow command?") ||
            contains_ci(screen, "press enter to confirm or esc to cancel"))
            return ST_NEEDS_INPUT;
    }

    return ST_IDLE;
}

/* Detect agent from command name */
static const char *detect_agent(const char *cmd) {
    const char *base = strrchr(cmd, '/');
    base = base ? base + 1 : cmd;
    if (strstr(base, "claude")) return "claude";
    if (strstr(base, "codex")) return "codex";
    return NULL;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: claude-dashboard-proxy <command> [args...]\n");
        return 1;
    }

    agent_type = detect_agent(argv[1]);
    init_real_tty();
    init_session_info();

    /* Save and set raw terminal mode */
    if (isatty(STDIN_FILENO)) {
        tcgetattr(STDIN_FILENO, &orig_termios);
        struct termios raw = orig_termios;
        cfmakeraw(&raw);
        tcsetattr(STDIN_FILENO, TCSANOW, &raw);
        raw_mode_set = 1;
        atexit(cleanup);
    }

    /* Open PTY */
    child_pid = forkpty(&master_fd, NULL, NULL, NULL);
    if (child_pid < 0) {
        perror("forkpty");
        return 1;
    }

    if (child_pid == 0) {
        /* Child: set PID env vars for cdash chat identity */
        char buf[16];
        snprintf(buf, sizeof(buf), "%d", getpid());
        setenv("CDASH_PID", buf, 1);
        snprintf(buf, sizeof(buf), "%d", getppid());
        setenv("CDASH_PROXY_PID", buf, 1);
        execvp(argv[1], &argv[1]);
        perror("execvp");
        _exit(127);
    }

    /* Parent: forward window size */
    struct winsize ws;
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0)
        ioctl(master_fd, TIOCSWINSZ, &ws);

    /* Set up signal handlers */
    signal(SIGWINCH, sigwinch_handler);
    signal(SIGCHLD, sigchld_handler);
    signal(SIGTERM, sigterm_handler);
    signal(SIGINT, sigint_handler);  /* Forward Ctrl+C to child */

    /* Write initial state, register cleanup */
    if (agent_type) {
        write_state(child_pid, ST_IDLE);
        atexit(cleanup_state);
    }

    /* Main loop */
    char buf[4096];
    struct timespec last_check;
    clock_gettime(CLOCK_MONOTONIC, &last_check);

    for (;;) {
        struct pollfd fds[2] = {
            { .fd = STDIN_FILENO, .events = POLLIN },
            { .fd = master_fd, .events = POLLIN },
        };

        int ret = poll(fds, 2, 100);
        if (ret < 0) {
            if (errno == EINTR) continue;
            break;
        }

        /* stdin → master (user input) */
        if (fds[0].revents & POLLIN) {
            ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
            if (n > 0) write(master_fd, buf, n);
            else if (n == 0) break;
        }

        /* master → stdout (agent output) */
        if (fds[1].revents & POLLIN) {
            ssize_t n = read(master_fd, buf, sizeof(buf));
            if (n > 0) {
                write(STDOUT_FILENO, buf, n);
                ring_append(buf, n);
                track_osc(buf, n);
            } else if (n == 0) break;
        }

        /* Check for HUP */
        if (fds[1].revents & (POLLHUP | POLLERR)) break;

        /* Periodic state detection */
        if (agent_type) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            long elapsed_ms = (now.tv_sec - last_check.tv_sec) * 1000 +
                              (now.tv_nsec - last_check.tv_nsec) / 1000000;
            if (elapsed_ms >= CHECK_INTERVAL_MS) {
                char screen[CLEAN_SIZE];
                int slen = ring_recent_clean(screen, CLEAN_SIZE - 1);
                state_t new_state = detect_state(screen, osc_title);

                /* Debug: dump screen + state when CDASH_DEBUG is set */
                if (getenv("CDASH_DEBUG")) {
                    FILE *dbg = fopen(STATE_DIR "/debug.log", "w");
                    if (dbg) {
                        fprintf(dbg, "state=%d title=[%s] slen=%d\n---\n%.800s\n",
                                new_state, osc_title, slen, screen);
                        fclose(dbg);
                    }
                }

                /* Debounce: working→idle */
                if (current_state == ST_WORKING && new_state == ST_IDLE) {
                    idle_confirmations++;
                    if (idle_confirmations < DEBOUNCE_COUNT) {
                        new_state = ST_WORKING;
                    } else {
                        idle_confirmations = 0;
                    }
                } else {
                    idle_confirmations = 0;
                }
                /* needs_input → other: no debounce, transition immediately */

                if (new_state != current_state) {
                    write_state(child_pid, new_state);
                    current_state = new_state;
                }
                last_check = now;
            }
        }

        /* Check for inject file when idle (use raw state, bypass debounce) */
        if (current_state == ST_IDLE || idle_confirmations > 0) {
            char inject_path[128];
            snprintf(inject_path, sizeof(inject_path), STATE_DIR "/%d.inject", child_pid);
            FILE *inj = fopen(inject_path, "r");
            if (inj) {
                char inject_buf[4096];
                size_t n = fread(inject_buf, 1, sizeof(inject_buf) - 1, inj);
                fclose(inj);
                unlink(inject_path);
                if (n > 0) {
                    inject_buf[n] = '\0';
                    /* Wrap accumulated messages in a single prompt */
                    const char *prefix = "New chat messages:\n";
                    const char *suffix = "Run `cdash chat read` for full context, `cdash chat send \"reply\"` to respond.";
                    write(master_fd, prefix, strlen(prefix));
                    /* Strip trailing newlines */
                    while (n > 0 && (inject_buf[n-1] == '\n' || inject_buf[n-1] == '\r')) n--;
                    inject_buf[n] = '\0';
                    write(master_fd, inject_buf, n);
                    write(master_fd, "\n", 1);
                    write(master_fd, suffix, strlen(suffix));
                    usleep(50000); /* 50ms delay before Enter */
                    write(master_fd, "\r", 1);
                }
            }
        }

        /* Check if child exited */
        int status;
        if (waitpid(child_pid, &status, WNOHANG) > 0) {
            /* Drain remaining output */
            for (;;) {
                ssize_t n = read(master_fd, buf, sizeof(buf));
                if (n <= 0) break;
                write(STDOUT_FILENO, buf, n);
            }
            /* Write final idle state (cleanup_state will remove it on exit) */
            if (agent_type) write_state(child_pid, ST_IDLE);
            cleanup();
            return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        }
    }

    /* Clean up */
    if (agent_type) write_state(child_pid, ST_IDLE);
    cleanup();

    int status;
    waitpid(child_pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
