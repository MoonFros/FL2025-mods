/* Minimal JSON reader for state.json.
 *
 * state.json is written by NGB_Presentation.lua and its schema is fixed, so
 * this is a *path lookup* rather than a general parser: it walks objects by
 * key, skips arrays, and returns a span into the original text. Nothing is
 * allocated, nothing is copied, and no input can make it run off the end -
 * every step is bounded by strlen of the buffer it was given.
 */
#include "ngb.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

static const char *skip_ws(const char *p)
{
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    return p;
}

/* Skips one JSON value. Returns pointer just past it, or NULL on malformed
 * input (which the caller treats as "field missing"). */
static const char *skip_value(const char *p)
{
    int depth = 0;
    p = skip_ws(p);
    if (*p == '"') {
        p++;
        while (*p) {
            if (*p == '\\' && p[1]) { p += 2; continue; }
            if (*p == '"') return p + 1;
            p++;
        }
        return NULL;
    }
    if (*p == '{' || *p == '[') {
        char open = *p, close = (open == '{') ? '}' : ']';
        depth = 0;
        while (*p) {
            if (*p == '"') {                 /* skip strings inside */
                p++;
                while (*p) {
                    if (*p == '\\' && p[1]) { p += 2; continue; }
                    if (*p == '"') break;
                    p++;
                }
                if (!*p) return NULL;
                p++;
                continue;
            }
            if (*p == open) depth++;
            else if (*p == close) {
                depth--;
                if (depth == 0) return p + 1;
            }
            p++;
        }
        return NULL;
    }
    /* number / true / false / null */
    while (*p && *p != ',' && *p != '}' && *p != ']' &&
           *p != ' ' && *p != '\t' && *p != '\r' && *p != '\n') p++;
    return p;
}

/* Finds "key" in the object at p (which must point at '{') and returns the
 * value span start. On success *vend points past the value. */
static const char *obj_find(const char *p, const char *key, int klen,
                           const char **vend)
{
    p = skip_ws(p);
    if (*p != '{') return NULL;
    p++;
    for (;;) {
        p = skip_ws(p);
        if (*p == '}' || *p == 0) return NULL;
        if (*p != '"') return NULL;
        p++;
        const char *ks = p;
        while (*p && *p != '"') {
            if (*p == '\\' && p[1]) p += 2;
            else p++;
        }
        if (!*p) return NULL;
        int kactual = (int)(p - ks);
        p++;
        p = skip_ws(p);
        if (*p != ':') return NULL;
        p = skip_ws(p + 1);
        const char *vs = p;
        const char *ve = skip_value(p);
        if (!ve) return NULL;
        if (kactual == klen && memcmp(ks, key, klen) == 0) {
            if (vend) *vend = ve;
            return vs;
        }
        p = skip_ws(ve);
        if (*p == ',') { p++; continue; }
        return NULL;
    }
}

/* Dotted path: "hud.style", "match.home.abbr". Arrays are not navigated. */
const char *ngb_json_path(const char *root, const char *path)
{
    if (!root || !path) return NULL;
    const char *p = skip_ws(root);
    const char *cur = skip_value(p);       /* whole document, for validation */
    if (!cur) return NULL;
    const char *node = p;
    const char *walk = path;
    while (*walk) {
        const char *dot = strchr(walk, '.');
        int klen = dot ? (int)(dot - walk) : (int)strlen(walk);
        if (klen <= 0) return NULL;
        const char *v = obj_find(node, walk, klen, NULL);
        if (!v) return NULL;
        v = skip_ws(v);
        if (!dot) return v;
        node = v;
        walk += klen + 1;
    }
    return NULL;
}

static void unescape_into(const char *v, int chars, char *out, int cap)
{
    int o = 0;
    for (int i = 0; i < chars && o < cap - 1; i++) {
        char c = v[i];
        if (c == '\\' && i + 1 < chars) {
            char n = v[++i];
            switch (n) {
            case 'n': c = '\n'; break;
            case 't': c = '\t'; break;
            case 'r': c = '\r'; break;
            case 'b': c = '\b'; break;
            case 'f': c = '\f'; break;
            case 'u': {
                /* keep it ASCII-clean: a \uXXXX becomes '?' unless it is a
                 * plain ASCII code point. Player names from Player.bin never
                 * need escapes; this is a safety net, not a decoder. */
                c = '?';
                i += 4;
                break;
            }
            default: c = n; break;
            }
        }
        out[o++] = c;
    }
    out[o] = 0;
}

int ngb_json_str(const char *root, const char *path, char *out, int cap,
                 const char *def)
{
    const char *v = ngb_json_path(root, path);
    if (out && cap > 0) {
        if (def) { strncpy(out, def, cap - 1); out[cap - 1] = 0; }
        else out[0] = 0;
    }
    if (!v) return 0;
    if (*v == '"') {
        const char *s = v + 1;
        const char *e = s;
        while (*e && *e != '"') {
            if (*e == '\\' && e[1]) e += 2;
            else e++;
        }
        if (!*e) return 0;
        if (out && cap > 0) unescape_into(s, (int)(e - s), out, cap);
        return 1;
    }
    if (!strncmp(v, "null", 4)) return 0;
    /* bare token: numbers and booleans are returned as text too */
    {
        const char *e = v;
        while (*e && *e != ',' && *e != '}' && *e != ']' &&
               *e != ' ' && *e != '\r' && *e != '\n') e++;
        if (out && cap > 0) {
            int n = (int)(e - v);
            if (n > cap - 1) n = cap - 1;
            memcpy(out, v, n);
            out[n] = 0;
        }
        return 1;
    }
}

double ngb_json_num(const char *root, const char *path, double def)
{
    const char *v = ngb_json_path(root, path);
    if (!v) return def;
    if (*v == '"') {
        char tmp[48];
        if (!ngb_json_str(root, path, tmp, sizeof tmp, "")) return def;
        return atof(tmp);
    }
    if (!strncmp(v, "true", 4)) return 1.0;
    if (!strncmp(v, "false", 5)) return 0.0;
    return atof(v);
}

int ngb_json_int(const char *root, const char *path, int def)
{
    const char *v = ngb_json_path(root, path);
    if (!v) return def;
    if (!strncmp(v, "true", 4)) return 1;
    if (!strncmp(v, "false", 5)) return 0;
    return (int)(atof(v) + (atof(v) >= 0 ? 0.5 : -0.5));
}

int ngb_json_bool(const char *root, const char *path, int def)
{
    const char *v = ngb_json_path(root, path);
    if (!v) return def;
    if (!strncmp(v, "true", 4)) return 1;
    if (!strncmp(v, "false", 5)) return 0;
    if (*v == '"') return (v[1] == '1' || v[1] == 't') ? 1 : 0;
    return (atof(v) != 0.0) ? 1 : 0;
}
