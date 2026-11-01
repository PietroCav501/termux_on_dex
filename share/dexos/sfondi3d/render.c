/* DeX OS: sfondi in 3D, calcolati qui (raymarching di forme a distanza con segno, SDF).
 *
 *   render SCENA PALETTE VARIANTE LARGHEZZA ALTEZZA CAMPIONI FILE.ppm
 *     SCENA     bloom | onde | sfere | nastro
 *     PALETTE   0..3 (vedi PALETTE[])
 *     VARIANTE  chiaro | scuro
 *     CAMPIONI  raggi per lato di pixel (2 = 4 raggi per pixel)
 *
 * Materiale "satinato": colore che scorre lungo la forma, luce principale con ombra morbida, luce di
 * riempimento, luce di contorno, riflesso di un set fotografico (pannelli di luce su uno sfondo
 * sfumato) con Fresnel, occlusione ambientale e un bagliore interno ai bordi sottili. Grana leggera
 * contro le fasce nelle sfumature. Tutti i core (pthread). Solo C e la libreria matematica.
 */
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct { float x, y, z; } v3;
static inline v3 V(float x, float y, float z) { v3 r = {x, y, z}; return r; }
static inline v3 add(v3 a, v3 b) { return V(a.x + b.x, a.y + b.y, a.z + b.z); }
static inline v3 sub(v3 a, v3 b) { return V(a.x - b.x, a.y - b.y, a.z - b.z); }
static inline v3 mul(v3 a, float s) { return V(a.x * s, a.y * s, a.z * s); }
static inline v3 hmul(v3 a, v3 b) { return V(a.x * b.x, a.y * b.y, a.z * b.z); }
static inline float dot(v3 a, v3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static inline float len(v3 a) { return sqrtf(dot(a, a)); }
static inline v3 norm(v3 a) { float l = len(a); return l > 0 ? mul(a, 1.0f / l) : a; }
static inline v3 cross(v3 a, v3 b) { return V(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x); }
static inline v3 mix3(v3 a, v3 b, float t) { return add(mul(a, 1 - t), mul(b, t)); }
static inline float clampf(float x, float a, float b) { return x < a ? a : x > b ? b : x; }
static inline float smooth(float a, float b, float x) { float t = clampf((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); }
static inline float smin(float a, float b, float k) { float h = clampf(0.5f + 0.5f * (b - a) / k, 0, 1); return b * (1 - h) + a * h - k * h * (1 - h); }
static inline v3 rotY(v3 p, float a) { float c = cosf(a), s = sinf(a); return V(c * p.x + s * p.z, p.y, -s * p.x + c * p.z); }
static inline v3 rotZ(v3 p, float a) { float c = cosf(a), s = sinf(a); return V(c * p.x - s * p.y, s * p.x + c * p.y, p.z); }
static inline v3 rotX(v3 p, float a) { float c = cosf(a), s = sinf(a); return V(p.x, c * p.y - s * p.z, s * p.y + c * p.z); }
static v3 hex(unsigned c) { return V(((c >> 16) & 255) / 255.0f, ((c >> 8) & 255) / 255.0f, (c & 255) / 255.0f); }
static v3 lin(v3 c) { return V(powf(c.x, 2.2f), powf(c.y, 2.2f), powf(c.z, 2.2f)); }

/* --- palette: tre colori della forma (base, centro, punta) e due dello sfondo -------------------- */
typedef struct { unsigned a, b, c, sfondo_chiaro, sfondo_scuro; const char *nome; } Palette;
static const Palette PALETTE[] = {
    {0x1b4dff, 0x5f8bff, 0xb8d4ff, 0xe9effa, 0x070b1c, "zaffiro"},
    {0xff5a3d, 0xff9a6b, 0xffd6b8, 0xfbefe8, 0x1a0b08, "corallo"},
    {0x00a39a, 0x3fd6b8, 0xc4f5e6, 0xe8f6f2, 0x041513, "giada"},
    {0x7b3cff, 0xc061ff, 0xffb8f0, 0xf3ecfb, 0x0f0719, "ametista"},
};

static int SCENA, PAL, SCURO;
static v3 CA, CB, CC, FONDO;

/* --- le scene: distanza dalla superficie più vicina e un parametro (0..1) per il colore --------- */
static float sdEllipsoid(v3 p, v3 r) {
    float k0 = len(V(p.x / r.x, p.y / r.y, p.z / r.z));
    float k1 = len(V(p.x / (r.x * r.x), p.y / (r.y * r.y), p.z / (r.z * r.z)));
    return k0 * (k0 - 1.0f) / k1;
}

#define PETALI 11
static float bloom(v3 p, float *t) {
    /* petali sottili e curvi che si aprono a ventaglio da un punto, uno sopra l'altro */
    float d = 1e9f;
    for (int i = 0; i < PETALI; i++) {
        float u = (float)i / (PETALI - 1);
        float a = -1.35f + u * 2.7f;                       /* apertura del ventaglio */
        v3 q = sub(p, V(0, -1.6f, 0.0f));
        q = rotZ(q, a);
        q = rotX(q, 0.10f + 0.30f * fabsf(u - 0.5f));        /* i petali esterni si piegano un po' verso di noi */
        q = rotY(q, (u - 0.5f) * 0.7f);
        q.y -= 1.75f;
        q.z += 0.30f * q.y * q.y - 0.10f;                    /* curvatura del petalo */
        q.z -= (u - 0.5f) * 0.08f;
        float di = sdEllipsoid(q, V(0.50f, 1.85f, 0.035f));
        /* colore: dalla base (profondo) alla punta (chiaro), con un po' di variazione tra i petali */
        if (di < d) { d = di; *t = clampf(clampf(q.y / 3.7f + 0.5f, 0, 1) * 0.8f + u * 0.2f, 0, 1); }
    }
    return d;
}

static float onde(v3 p, float *t) {
    /* un telo lucido che ondeggia, visto di traverso */
    float h = 0.28f * sinf(p.x * 1.3f + 0.6f * sinf(p.z * 1.1f)) + 0.16f * sinf(p.z * 2.1f + p.x * 0.7f)
            + 0.05f * sinf(p.x * 4.2f + p.z * 3.1f);
    *t = clampf(0.5f + 0.5f * sinf(p.x * 0.8f + p.z * 0.5f), 0, 1);
    return (p.y - h - -0.4f) * 0.6f;
}

static float sfere(v3 p, float *t) {
    /* gocce morbide che si fondono */
    static const float S[][4] = {{-0.9f, 0.1f, 0.2f, 0.85f}, {0.55f, 0.55f, -0.2f, 0.65f}, {0.9f, -0.55f, 0.3f, 0.55f},
                                 {-0.1f, -0.8f, -0.4f, 0.45f}, {-1.6f, 0.95f, -0.6f, 0.38f}, {1.7f, 0.65f, 0.4f, 0.32f}};
    float d = 1e9f, best = 1e9f;
    for (int i = 0; i < 6; i++) {
        float di = len(sub(p, V(S[i][0], S[i][1], S[i][2]))) - S[i][3];
        if (di < best) { best = di; *t = i / 5.0f; }
        d = i ? smin(d, di, 0.32f) : di;
    }
    return d;
}

static float nastro(v3 p, float *t) {
    /* un nastro largo e sottile che si avvolge su sé stesso */
    float d = 1e9f;
    for (int k = 0; k < 3; k++) {
        v3 q = rotZ(p, k * 2.094f);
        float ang = atan2f(q.y, q.x);
        float r = len(V(q.x, q.y, 0));
        v3 c = V(r - 1.25f, q.z + 0.25f * sinf(ang * 2 + k), 0);
        float tw = ang * 1.5f + k;
        v3 cr = V(cosf(tw) * c.x - sinf(tw) * c.y, sinf(tw) * c.x + cosf(tw) * c.y, 0);
        float di = (len(V(fmaxf(fabsf(cr.x) - 0.32f, 0), fmaxf(fabsf(cr.y) - 0.025f, 0), 0)) - 0.01f) * 0.7f;
        if (di < d) { d = di; *t = clampf(0.5f + 0.5f * sinf(ang + k), 0, 1); }
    }
    return d;
}

static float scena(v3 p, float *t) {
    switch (SCENA) {
    case 0: return bloom(p, t);
    case 1: return onde(p, t);
    case 2: return sfere(p, t);
    default: return nastro(p, t);
    }
}
static float dist(v3 p) { float t; return scena(p, &t); }

static v3 normale(v3 p) {
    const float e = 0.0015f;
    return norm(V(dist(add(p, V(e, 0, 0))) - dist(sub(p, V(e, 0, 0))),
                  dist(add(p, V(0, e, 0))) - dist(sub(p, V(0, e, 0))),
                  dist(add(p, V(0, 0, e))) - dist(sub(p, V(0, 0, e)))));
}

static float ombra(v3 o, v3 l) {   /* ombra morbida verso la luce */
    float r = 1, t = 0.02f;
    for (int i = 0; i < 48 && t < 6; i++) {
        float h = dist(add(o, mul(l, t)));
        r = fminf(r, 10 * h / t);
        if (r < 0.001f) break;
        t += clampf(h, 0.01f, 0.25f);
    }
    return clampf(r, 0, 1);
}

static float occlusione(v3 p, v3 n) {
    float o = 0, s = 1;
    for (int i = 1; i <= 5; i++) {
        float h = 0.03f * i;
        o += (h - dist(add(p, mul(n, h)))) * s;
        s *= 0.7f;
    }
    return clampf(1 - 2.5f * o, 0, 1);
}

/* il set fotografico: sfondo sfumato e pannelli di luce (si vedono nei riflessi) */
static v3 ambiente(v3 d) {
    v3 base = mix3(FONDO, mix3(FONDO, CC, SCURO ? 0.25f : 0.35f), smooth(-0.3f, 1.0f, d.y));
    float pannello = smooth(0.82f, 0.95f, dot(d, norm(V(-0.6f, 0.7f, 0.35f))));         /* luce grande in alto a sinistra */
    float striscia = smooth(0.93f, 0.985f, dot(d, norm(V(0.8f, 0.25f, 0.5f))));          /* striscia a destra */
    v3 c = add(base, mul(V(1, 1, 1), pannello * (SCURO ? 1.6f : 2.0f)));
    return add(c, mul(mix3(CC, V(1, 1, 1), 0.5f), striscia * 1.2f));
}

static v3 sfondo(float u, float v) {
    /* bagliore dietro la forma e vignettatura */
    float r = len(V(u * 0.9f, v + 0.15f, 0));
    v3 c = mix3(mix3(FONDO, CB, SCURO ? 0.45f : 0.30f), FONDO, smooth(0.0f, 1.3f, r));
    float vig = smooth(1.6f, 0.4f, len(V(u * 0.75f, v, 0)));
    return SCURO ? mul(c, 0.55f + 0.45f * vig) : mix3(mul(FONDO, 0.94f), c, vig);
}

static v3 colore_forma(float t) {   /* base più profonda della palette, poi centro e punta */
    v3 fondo = mul(CA, 0.35f);
    if (t < 0.3f) return mix3(fondo, CA, t / 0.3f);
    if (t < 0.7f) return mix3(CA, CB, (t - 0.3f) / 0.4f);
    return mix3(CB, CC, (t - 0.7f) / 0.3f);
}

static v3 traccia(v3 ro, v3 rd, float u, float v) {
    float t = 0, mat = 0;
    int colpito = 0;
    for (int i = 0; i < 220 && t < 20; i++) {
        float m, h = scena(add(ro, mul(rd, t)), &m);
        if (h < 0.0008f * (1 + t)) { colpito = 1; mat = m; break; }
        t += h * 0.9f;
    }
    if (!colpito) return sfondo(u, v);
    v3 p = add(ro, mul(rd, t)), n = normale(p);
    if (dot(n, rd) > 0) n = mul(n, -1);   /* fogli sottili: la faccia verso di noi */
    v3 base = colore_forma(mat);
    v3 L = norm(V(-0.55f, 0.75f, 0.6f)), F = norm(V(0.7f, -0.1f, 0.7f)), R = norm(V(0.3f, 0.4f, -0.85f));
    float dif = clampf(dot(n, L), 0, 1) * (0.35f + 0.65f * ombra(add(p, mul(n, 0.004f)), L));
    float fill = clampf(dot(n, F) * 0.5f + 0.5f, 0, 1) * 0.35f;
    float rim = powf(clampf(1 + dot(n, rd), 0, 1), 3) * 0.9f;
    float ao = occlusione(p, n);
    v3 refl = sub(rd, mul(n, 2 * dot(n, rd)));
    float fres = 0.04f + 0.96f * powf(clampf(1 + dot(n, rd), 0, 1), 5);
    v3 spec = mul(ambiente(refl), fres * (SCURO ? 0.85f : 0.65f));
    float lucido = powf(clampf(dot(refl, L), 0, 1), 60) * 1.4f;
    /* bagliore interno: le parti sottili lasciano passare la luce del colore più chiaro */
    float bordo = powf(clampf(1 - fabsf(dot(n, rd)), 0, 1), 2);
    v3 c = mul(base, ((SCURO ? 0.05f : 0.12f) + dif * 0.85f + fill * 0.6f) * ao);
    c = add(c, mul(mix3(CC, V(1, 1, 1), 0.3f), rim * 0.35f + bordo * 0.35f));
    c = add(c, spec);
    c = add(c, mul(V(1, 1, 1), lucido * ombra(add(p, mul(n, 0.004f)), L)));
    (void)R;
    /* un velo di nebbia verso lo sfondo, per la profondità */
    return mix3(c, sfondo(u, v), smooth(6.0f, 12.0f, t));
}

/* --- immagine ---------------------------------------------------------------------------------- */
static int LW, LH, CAMP;
static uint8_t *IMG;
static v3 CAM_O, CAM_F, CAM_R, CAM_U;
static float FOV;
static int RIGA;
static pthread_mutex_t MX = PTHREAD_MUTEX_INITIALIZER;

static float tonemap(float x) { x = x / (1 + x * 0.25f); return powf(clampf(x, 0, 1), 1 / 2.2f); }

static uint32_t hash(uint32_t x) { x ^= x >> 16; x *= 0x7feb352d; x ^= x >> 15; x *= 0x846ca68b; x ^= x >> 16; return x; }

static void *lavora(void *arg) {
    (void)arg;
    for (;;) {
        pthread_mutex_lock(&MX);
        int y = RIGA++;
        pthread_mutex_unlock(&MX);
        if (y >= LH) break;
        for (int x = 0; x < LW; x++) {
            v3 acc = V(0, 0, 0);
            for (int sy = 0; sy < CAMP; sy++)
                for (int sx = 0; sx < CAMP; sx++) {
                    float px = (x + (sx + 0.5f) / CAMP) / LW * 2 - 1, py = 1 - (y + (sy + 0.5f) / CAMP) / LH * 2;
                    float u = px * LW / (float)LH, v = py;
                    v3 rd = norm(add(add(mul(CAM_R, u * FOV), mul(CAM_U, v * FOV)), CAM_F));
                    acc = add(acc, traccia(CAM_O, rd, u, v));
                }
            acc = mul(acc, 1.0f / (CAMP * CAMP));
            float g = ((hash(y * 9973u + x * 31u) & 1023) / 1023.0f - 0.5f) * (SCURO ? 0.022f : 0.016f);   /* grana */
            uint8_t *o = IMG + 3 * ((size_t)y * LW + x);
            o[0] = (uint8_t)(255 * clampf(tonemap(acc.x) + g, 0, 1));
            o[1] = (uint8_t)(255 * clampf(tonemap(acc.y) + g, 0, 1));
            o[2] = (uint8_t)(255 * clampf(tonemap(acc.z) + g, 0, 1));
        }
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 8) {
        fprintf(stderr, "uso: render bloom|onde|sfere|nastro PALETTE chiaro|scuro LARGHEZZA ALTEZZA CAMPIONI FILE.ppm\n");
        return 2;
    }
    const char *sc[] = {"bloom", "onde", "sfere", "nastro"};
    SCENA = -1;
    for (int i = 0; i < 4; i++) if (!strcmp(argv[1], sc[i])) SCENA = i;
    PAL = atoi(argv[2]) & 3;
    SCURO = !strcmp(argv[3], "scuro");
    LW = atoi(argv[4]); LH = atoi(argv[5]); CAMP = atoi(argv[6]);
    if (SCENA < 0 || LW <= 0 || LH <= 0 || CAMP <= 0) return 2;
    const Palette *P = &PALETTE[PAL];
    CA = lin(hex(P->a)); CB = lin(hex(P->b)); CC = lin(hex(P->c));
    FONDO = lin(hex(SCURO ? P->sfondo_scuro : P->sfondo_chiaro));
    /* inquadratura per scena */
    static const float CAM[][7] = {  /* origine x y z, guarda x y z, campo */
        {0.2f, -0.2f, 6.6f, 0.6f, 0.7f, 0, 0.46f},
        {0, 0.85f, 3.4f, 0.2f, -0.35f, -1.0f, 0.50f},
        {0.3f, 0.1f, 4.3f, 0.15f, 0.05f, 0, 0.50f},
        {1.1f, 0.7f, 3.5f, 0.55f, 0.05f, 0, 0.50f},
    };
    CAM_O = V(CAM[SCENA][0], CAM[SCENA][1], CAM[SCENA][2]);
    CAM_F = norm(sub(V(CAM[SCENA][3], CAM[SCENA][4], CAM[SCENA][5]), CAM_O));
    CAM_R = norm(cross(CAM_F, V(0, 1, 0)));
    CAM_U = cross(CAM_R, CAM_F);
    FOV = CAM[SCENA][6];
    IMG = malloc((size_t)LW * LH * 3);
    if (!IMG) return 1;
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    if (n < 1) n = 4;
    if (n > 32) n = 32;
    pthread_t th[32];
    for (long i = 0; i < n; i++) pthread_create(&th[i], NULL, lavora, NULL);
    for (long i = 0; i < n; i++) pthread_join(th[i], NULL);
    FILE *f = fopen(argv[7], "wb");
    if (!f) return 1;
    fprintf(f, "P6\n%d %d\n255\n", LW, LH);
    fwrite(IMG, 1, (size_t)LW * LH * 3, f);
    fclose(f);
    return 0;
}
