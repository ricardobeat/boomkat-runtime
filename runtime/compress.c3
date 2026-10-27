// Streaming gzip, deflate and raw deflate over zlib. JS holds a codec by id
// and pushes chunks through it on the loop thread.
module bkr;

import boomkat;
import bkr::zlib;
import std::collections::list;
import std::collections::map;

enum CodecFormat : char {
    GZIP,
    DEFLATE,
    DEFLATE_RAW,
}

struct Codec {
    ZStream z;
    bool compress;
    bool ended; // a decompressor saw the end of its stream
}

tlocal HashMap{ulong, Codec*} g_codecs;
tlocal ulong g_codec_next;

const usz CODEC_CHUNK = 64 * 1024;

fn CInt window_bits(CodecFormat format) {
    switch (format) {
        case GZIP: return 15 + 16;
        case DEFLATE: return 15;
        case DEFLATE_RAW: return -15;
    }
}

// zlibNew(format, compress) -> id
fn void js_zlib_new(JsCtx ctx, void* udata) {
    if (!g_codecs.is_initialized()) g_codecs.init(mem);
    int format = ctx.arg(0).as_int(0);
    if (format < 0 || format >= CodecFormat::len) {
        ctx.throw_error(TYPE, "unsupported compression format");
        return;
    }
    Codec* c = mem::new(Codec);
    c.compress = ctx.arg(1).as_bool() ?? false;
    CInt bits = window_bits((CodecFormat)format);
    CInt rc = c.compress
        ? zlib::deflate_init2(&c.z, zlib::Z_DEFAULT_COMPRESSION, zlib::Z_DEFLATED, bits, 8,
                              zlib::Z_DEFAULT_STRATEGY, zlib::zlib_version(), (CInt)ZStream::size)
        : zlib::inflate_init2(&c.z, bits, zlib::zlib_version(), (CInt)ZStream::size);
    if (rc != zlib::Z_OK) {
        free(c);
        ctx.throw_error(TYPE, "could not start the compression stream");
        return;
    }
    ulong id = ++g_codec_next;
    g_codecs.set(id, c);
    ctx.ret_number((double)id);
}

fn Codec* JsCtx.codec(self) => g_codecs.get((ulong)(self.arg(0).as_number() ?? 0)) ?? null;

// zlibPush(id, bytes, finish) -> the output the input produced
fn void js_zlib_push(JsCtx ctx, void* udata) {
    Codec* c = ctx.codec();
    if (!c) {
        ctx.throw_error(TYPE, "the compression stream is closed");
        return;
    }
    char[] input = ctx.arg(1).bytes();
    bool finish  = ctx.arg(2).as_bool() ?? false;
    if (!c.compress && c.ended && input.len) {
        ctx.throw_error(TYPE, "data after the end of the compressed stream");
        return;
    }
    List{char} out;
    out.init(mem, CODEC_CHUNK);
    defer out.free();
    c.z.next_in = input.ptr;
    c.z.avail_in = (uint)input.len;
    char[CODEC_CHUNK] buf;
    for (;;) {
        c.z.next_out = &buf;
        c.z.avail_out = (uint)buf.len;
        CInt flush = finish ? zlib::Z_FINISH : zlib::Z_NO_FLUSH;
        CInt rc = c.compress ? zlib::deflate(&c.z, flush) : zlib::inflate(&c.z, zlib::Z_NO_FLUSH);
        out.push_all(buf[:buf.len - c.z.avail_out]);
        if (rc == zlib::Z_STREAM_END) {
            if (c.compress) break;
            c.ended = true;
            if (c.z.avail_in) {
                ctx.throw_error(TYPE, "data after the end of the compressed stream");
                return;
            }
            break;
        }
        if (rc != zlib::Z_OK && rc != zlib::Z_BUF_ERROR) {
            ctx.throw_error(TYPE, "invalid compressed data");
            return;
        }
        // More output is pending only while zlib filled the whole buffer.
        if (c.z.avail_out != 0 && c.z.avail_in == 0 && (!finish || !c.compress)) break;
        if (rc == zlib::Z_BUF_ERROR && c.z.avail_out != 0) break;
    }
    if (finish && !c.compress && !c.ended) {
        ctx.throw_error(TYPE, "the compressed stream ended early");
        return;
    }
    ctx.ret_bytes(copy_bytes(out.array_view()));
}

// zlibEnd(id): releases the codec; safe to repeat
fn void js_zlib_end(JsCtx ctx, void* udata) {
    ulong id = (ulong)(ctx.arg(0).as_number() ?? 0);
    Codec* c = g_codecs.get(id) ?? null;
    if (!c) return;
    g_codecs.remove(id);
    if (c.compress) {
        zlib::deflate_end(&c.z);
    } else {
        zlib::inflate_end(&c.z);
    }
    free(c);
}

const Native[] ZLIB_NATIVES = {
    { "zlibNew", &js_zlib_new, 2 },
    { "zlibPush", &js_zlib_push, 3 },
    { "zlibEnd", &js_zlib_end, 1 },
};
