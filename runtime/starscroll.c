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

/* --- space objects at 3 scales --- */

/* saturn */
static const char *saturn_sm[] = {
    "─◯─",
};
static const char *saturn_md[] = {
    "  ╌╌╌╌╌  ",
    " ╌(██)╌  ",
    "  ╌╌╌╌╌  ",
};
static const char *saturn_lg[] = {
    "    ╌╌╌╌╌╌╌╌╌╌╌    ",
    "  ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌  ",
    " ╌╌╌ ▄████████▄ ╌╌╌ ",
    " ╌╌ █          █ ╌╌ ",
    " ╌╌╌ ▀████████▀ ╌╌╌ ",
    "  ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌  ",
    "    ╌╌╌╌╌╌╌╌╌╌╌    ",
};

/* galaxy */
static const char *galaxy_sm[] = {
    " ※ ",
};
static const char *galaxy_md[] = {
    "  · ·  ",
    " ·※· · ",
    " · ·   ",
};
static const char *galaxy_lg[] = {
    "     · ·  · ·     ",
    "   ·  · ·  · · ·  ",
    "  · · · ✦ · · ·   ",
    "   · ·  · ·  ·    ",
    "     ·  · ·       ",
};

/* comet */
static const char *comet_sm[] = {
    "- - ☄",
};
static const char *comet_md[] = {
    "╌╌╌╌ ·☄  ",
    "   ╌╌· · ",
};
static const char *comet_lg[] = {
    "╌╌╌╌╌╌╌╌ · ·☄· ",
    "     ╌╌╌╌· · ·  ",
    "         ╌╌· ·   ",
};

/* planet (jupiter-like) */
static const char *jupiter_sm[] = {
    " ◉ ",
};
static const char *jupiter_md[] = {
    "  ▄██▄  ",
    " █▓▓▓▓█ ",
    " █░░░░█ ",
    "  ▀██▀  ",
};
static const char *jupiter_lg[] = {
    "    ▄██████▄    ",
    "  █▓▓▓▓▓▓▓▓▓▓█  ",
    " █░░░░░░░░░░░░█ ",
    " █▓▓▓▓▓▓▓▓▓▓▓▓█ ",
    " █░░░░░░░░░░░░█ ",
    "  █▓▓▓▓▓▓▓▓▓▓█  ",
    "    ▀██████▀    ",
};

/* rocket */
static const char *rocket_sm[] = {
    " ▶ ",
};
static const char *rocket_md[] = {
    "  ╱▔╲  ",
    " │▪▪│  ",
    " │  │  ",
    " ╱╲╱╲  ",
    " ▼▼▼   ",
};
static const char *rocket_lg[] = {
    "     ╱▔╲     ",
    "    ╱   ╲    ",
    "   │ ▪ ▪ │   ",
    "   │     │   ",
    "  ╱│     │╲  ",
    " ╱ │     │ ╲ ",
    "╱  ╱╲   ╱╲  ╲",
    "   ▼▼▼ ▼▼▼   ",
};

/* moon */
static const char *moon_sm[] = {
    " ☽ ",
};
static const char *moon_md[] = {
    " ▄██  ",
    "██    ",
    " ▀██  ",
};
static const char *moon_lg[] = {
    "   ▄████   ",
    "  ██       ",
    " ██        ",
    "  ██       ",
    "   ▀████   ",
};

/* ufo */
static const char *ufo_sm[] = {
    "╺◉╸",
};
static const char *ufo_md[] = {
    "  ▄▄▄  ",
    "╺█◉◉█╸",
    "  ▀▀▀  ",
};
static const char *ufo_lg[] = {
    "     ▄▄▄     ",
    "   ▄█   █▄   ",
    "╺██ ◉   ◉ ██╸",
    "   ▀█▄▄▄█▀   ",
    "     ▀▀▀     ",
};

struct monster_def {
    const char **sm;  int sm_h;  int sm_w;
    const char **md;  int md_h;  int md_w;
    const char **lg;  int lg_h;  int lg_w;
};

static struct monster_def objects[] = {
    { saturn_sm,  1,  3,  saturn_md,  3,  9,  saturn_lg,  7, 19 },
    { galaxy_sm,  1,  3,  galaxy_md,  3,  7,  galaxy_lg,  5, 18 },
    { comet_sm,   1,  5,  comet_md,   2,  9,  comet_lg,   3, 16 },
    { jupiter_sm, 1,  3,  jupiter_md, 4,  8,  jupiter_lg, 7, 16 },
    { rocket_sm,  1,  3,  rocket_md,  5,  7,  rocket_lg,  8, 13 },
    { moon_sm,    1,  3,  moon_md,    3,  6,  moon_lg,    5, 11 },
    { ufo_sm,     1,  4,  ufo_md,    3,  7,  ufo_lg,     5, 13 },
};
#define N_OBJECTS 7

struct creature {
    int type;
    int x;
    int y;
    int active;
    int scale;
};

#define MAX_CREATURES 12

static struct creature creatures[MAX_CREATURES];

/* star field — persistent dots at fixed positions */
#define MAX_STARS 200
static struct { int r; int c; int bright; int speed; } stars[MAX_STARS];
static int n_stars;

static const char *star_chars[] = { ".", "·", "∙", "✦", "✧", "*", "⋆" };
#define N_STAR_CHARS 7

/* ANSI colors: space palette */
static const char *colors[] = {
    "\033[38;5;57m",   /* deep purple */
    "\033[38;5;63m",   /* blue-violet */
    "\033[38;5;69m",   /* cornflower */
    "\033[38;5;105m",  /* medium purple */
    "\033[38;5;141m",  /* light purple */
    "\033[38;5;214m",  /* gold */
    "\033[38;5;203m",  /* warm red */
    "\033[38;5;74m",   /* sky blue */
    "\033[38;5;255m",  /* white */
    "\033[38;5;245m",  /* dim gray */
};
#define N_COLORS 10

static void init_stars(void) {
    n_stars = ws.ws_row * ws.ws_col / 40;
    if (n_stars > MAX_STARS) n_stars = MAX_STARS;
    for (int i = 0; i < n_stars; i++) {
        stars[i].r = 1 + rand() % ws.ws_row;
        stars[i].c = 1 + rand() % ws.ws_col;
        stars[i].bright = rand() % 3;
        stars[i].speed = 1 + rand() % 3;
    }
}

static void spawn_creature(struct creature *c) {
    c->type = rand() % N_OBJECTS;
    c->x = ws.ws_col + 2;
    c->y = 2 + rand() % (ws.ws_row > 10 ? ws.ws_row - 10 : 1);
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

static void draw_stars(int tick) {
    for (int i = 0; i < n_stars; i++) {
        int c = stars[i].c - (tick * stars[i].speed) % ws.ws_col;
        if (c < 1) c += ws.ws_col;
        int twinkle = (tick + i * 7) % 12;
        if (twinkle < 2) continue; /* blink off */
        const char *color;
        if (stars[i].bright == 0)
            color = "\033[38;5;240m";
        else if (stars[i].bright == 1)
            color = "\033[38;5;245m";
        else
            color = "\033[38;5;255m";
        int ch = (i + tick / 4) % N_STAR_CHARS;
        printf("\033[%d;%dH%s%s", stars[i].r, c, color, star_chars[ch]);
    }
}

static void draw_creature(struct creature *c) {
    struct monster_def *m = &objects[c->type];
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
    init_stars();

    printf("\033[?1049h\033[?25l");

    memset(creatures, 0, sizeof(creatures));

    int tick = 0;
    int spawn_timer = 0;

    while (running) {
        /* black background */
        printf("\033[2J\033[48;5;0m");

        draw_stars(tick);

        spawn_timer++;
        if (spawn_timer > 18 + rand() % 25) {
            spawn_timer = 0;
            for (int i = 0; i < MAX_CREATURES; i++) {
                if (!creatures[i].active) {
                    spawn_creature(&creatures[i]);
                    break;
                }
            }
        }

        for (int i = 0; i < MAX_CREATURES; i++) {
            if (!creatures[i].active) continue;
            creatures[i].x -= 1 + creatures[i].scale;
            update_scale(&creatures[i]);

            struct monster_def *m = &objects[creatures[i].type];
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

    printf("\033[?1049l\033[?25h\033[0m");
    return 0;
}
