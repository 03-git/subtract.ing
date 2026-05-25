#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <time.h>

static volatile int running = 1;
static struct winsize ws;

static void die(int sig) { (void)sig; running = 0; }

static void get_size(void) {
    ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws);
    if (ws.ws_row == 0) ws.ws_row = 24;
    if (ws.ws_col == 0) ws.ws_col = 80;
}

/* --- monsters at 3 scales --- */

/* each monster: array of strings per scale, height per scale */

/* kraken */
static const char *kraken_sm[] = {
    " ~∽~ ",
    " ◉)  ",
    " /|\\ ",
};
static const char *kraken_md[] = {
    "  ≈~∽~≈  ",
    "  ( ◉ )  ",
    " ╱│╲╱│╲ ",
    " ╱ │ ╲  ",
    "  ┘   └  ",
};
static const char *kraken_lg[] = {
    "    ≈≈~∽∽~≈≈    ",
    "   ╱ ▔▔▔▔▔ ╲   ",
    "  │  ◉   ◉  │  ",
    "  │    ▽    │  ",
    "   ╲▁▁▁▁▁▁▁╱   ",
    "  ╱│╲ ╱│╲ ╱│╲  ",
    " ╱ │ ╲│ ╲│ │ ╲ ",
    " ┘  └ ┘  └ ┘  └ ",
};

/* serpent */
static const char *serpent_sm[] = {
    "~━◇>",
};
static const char *serpent_md[] = {
    "  ╭◇━━╮    ",
    "~━╯    ╰━━>",
};
static const char *serpent_lg[] = {
    "     ╭━◇━━╮       ",
    "  ╭━━╯ ◉◉ ╰━━╮   ",
    "~━╯            ╰━>",
    "  ≈  ≈   ≈  ≈  ≈  ",
};

/* leviathan */
static const char *levi_sm[] = {
    "▄███▄",
    "◉━━━>",
    "▀███▀",
};
static const char *levi_md[] = {
    "  ▄██████▄  ",
    " █ ◉    ◉ █ ",
    " █▄▄████▄▄█━>",
    "  ▀██████▀  ",
};
static const char *levi_lg[] = {
    "    ▄████████████▄    ",
    "  ▄█              █▄  ",
    " █   ◉          ◉   █ ",
    " █                   █━━>",
    " █▄  ▄▄▄▄▄▄▄▄▄▄▄▄  ▄█ ",
    "  ▀████████████████▀  ",
    "    ≈≈≈≈≈≈≈≈≈≈≈≈≈≈    ",
};

/* jellyfish */
static const char *jelly_sm[] = {
    " ╭─╮ ",
    " │∘│ ",
    " ┆┆┆ ",
};
static const char *jelly_md[] = {
    "  ╭───╮  ",
    "  │∘ ∘│  ",
    "  ╰───╯  ",
    "  ┆┆┆┆┆  ",
    "  ┆ ┆ ┆  ",
};
static const char *jelly_lg[] = {
    "   ╭─────────╮   ",
    "  ╭╯  ∘   ∘  ╰╮  ",
    "  │             │  ",
    "  ╰─────────────╯  ",
    "   ┆┆ ┆┆ ┆┆ ┆┆   ",
    "   ┆  ┆  ┆  ┆    ",
    "   ┆  ┆  ┆  ┆    ",
};

/* whale */
static const char *whale_sm[] = {
    " ▄▄▄  ",
    "◉━━━▶ ",
    " ▀▀▀  ",
};
static const char *whale_md[] = {
    "    ▄▄▄▄▄▄    ",
    "  ▄█      █▄  ",
    " ◉          ▶ ",
    "  ▀█▄▄▄▄▄▄█▀  ",
};
static const char *whale_lg[] = {
    "      ▄▄▄▄▄▄▄▄▄▄      ",
    "    ▄█            █▄    ",
    "  ▄█    ◉           █▄  ",
    " █                    ▶ ",
    "  ▀█▄                █▀  ",
    "    ▀█▄▄▄▄▄▄▄▄▄▄▄▄█▀    ",
    "       ≈≈≈≈≈≈≈≈≈≈       ",
};

struct monster_def {
    const char **sm;  int sm_h;  int sm_w;
    const char **md;  int md_h;  int md_w;
    const char **lg;  int lg_h;  int lg_w;
};

static struct monster_def monsters[] = {
    { kraken_sm,  3,  5,  kraken_md,  5,  9,  kraken_lg,  8, 17 },
    { serpent_sm, 1,  5,  serpent_md, 2, 11,  serpent_lg, 4, 19 },
    { levi_sm,    3,  5,  levi_md,   4, 13,  levi_lg,   7, 22 },
    { jelly_sm,   3,  6,  jelly_md,  5,  9,  jelly_lg,  7, 17 },
    { whale_sm,   3,  7,  whale_md,  4, 14,  whale_lg,  7, 22 },
};
#define N_MONSTERS 5

struct creature {
    int type;
    int x;
    int y;
    int active;
    int scale; /* 0=sm 1=md 2=lg */
};

#define MAX_CREATURES 12

static struct creature creatures[MAX_CREATURES];

static const char *wave_chars[] = { "~", "≈", "∽", "～", "〜" };
#define N_WAVE 5

/* ANSI colors: ocean blues and greens */
static const char *colors[] = {
    "\033[38;5;24m",  /* deep blue */
    "\033[38;5;30m",  /* teal */
    "\033[38;5;36m",  /* cyan-green */
    "\033[38;5;66m",  /* slate */
    "\033[38;5;67m",  /* steel blue */
    "\033[38;5;73m",  /* medium cyan */
    "\033[38;5;109m", /* light steel */
    "\033[38;5;37m",  /* dark cyan */
};
#define N_COLORS 8

static void spawn_creature(struct creature *c) {
    c->type = rand() % N_MONSTERS;
    c->x = ws.ws_col + 2;
    c->y = 2 + rand() % (ws.ws_row > 8 ? ws.ws_row - 8 : 1);
    c->active = 1;
    c->scale = 0;
}

static void update_scale(struct creature *c) {
    int third = ws.ws_col / 3;
    int center = ws.ws_col / 2;
    int dist = abs(c->x - center);
    if (dist < third / 2)
        c->scale = 2;
    else if (dist < third)
        c->scale = 1;
    else
        c->scale = 0;
}

static void draw_waves(int tick) {
    int r, c;
    for (r = 0; r < (int)ws.ws_row; r++) {
        printf("\033[%d;1H", r + 1);
        for (c = 0; c < (int)ws.ws_col; c++) {
            int idx = (c + r * 3 + tick) % N_WAVE;
            int ci = (r + c / 7) % N_COLORS;
            /* sparse waves — most cells empty */
            if ((c + r + tick) % 7 == 0)
                printf("%s%s", colors[ci], wave_chars[idx]);
            else
                printf(" ");
        }
    }
}

static void draw_creature(struct creature *c) {
    struct monster_def *m = &monsters[c->type];
    const char **art;
    int h;

    switch (c->scale) {
    case 0: art = m->sm; h = m->sm_h; break;
    case 1: art = m->md; h = m->md_h; break;
    default: art = m->lg; h = m->lg_h; break;
    }

    int color_idx = c->type % N_COLORS;

    for (int i = 0; i < h; i++) {
        int row = c->y + i;
        if (row < 1 || row > (int)ws.ws_row) continue;
        if (c->x < 1) continue;
        printf("\033[%d;%dH%s%s", row, c->x, colors[color_idx], art[i]);
    }
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;

    signal(SIGINT, die);
    signal(SIGTERM, die);
    signal(SIGWINCH, (void(*)(int))get_size);

    srand(time(NULL));
    get_size();

    /* hide cursor, alt screen */
    printf("\033[?1049h\033[?25l");

    memset(creatures, 0, sizeof(creatures));

    int tick = 0;
    int spawn_timer = 0;

    while (running) {
        printf("\033[2J");

        draw_waves(tick);

        /* spawn new creatures */
        spawn_timer++;
        if (spawn_timer > 15 + rand() % 20) {
            spawn_timer = 0;
            for (int i = 0; i < MAX_CREATURES; i++) {
                if (!creatures[i].active) {
                    spawn_creature(&creatures[i]);
                    break;
                }
            }
        }

        /* update and draw creatures */
        for (int i = 0; i < MAX_CREATURES; i++) {
            if (!creatures[i].active) continue;
            creatures[i].x -= 1 + creatures[i].scale;
            update_scale(&creatures[i]);

            struct monster_def *m = &monsters[creatures[i].type];
            int w = creatures[i].scale == 0 ? m->sm_w :
                    creatures[i].scale == 1 ? m->md_w : m->lg_w;

            if (creatures[i].x + w < 0) {
                creatures[i].active = 0;
                continue;
            }
            draw_creature(&creatures[i]);
        }

        printf("\033[0m");
        fflush(stdout);
        usleep(80000);
        tick++;
    }

    /* restore terminal */
    printf("\033[?1049l\033[?25h\033[0m");
    return 0;
}
