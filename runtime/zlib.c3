// The system zlib, for CompressionStream, DecompressionStream and fetch
// content decoding.
module bkr::zlib @link("z");

struct ZStream {
    char* next_in;
    uint avail_in;
    ulong total_in;
    char* next_out;
    uint avail_out;
    ulong total_out;
    char* msg;
    void* state;
    void* zalloc;
    void* zfree;
    void* opaque;
    CInt data_type;
    ulong adler;
    ulong reserved;
}

const CInt Z_OK = 0;
const CInt Z_STREAM_END = 1;
const CInt Z_BUF_ERROR = -5;
const CInt Z_NO_FLUSH = 0;
const CInt Z_SYNC_FLUSH = 2;
const CInt Z_FINISH = 4;
const CInt Z_DEFAULT_COMPRESSION = -1;
const CInt Z_DEFLATED = 8;
const CInt Z_DEFAULT_STRATEGY = 0;

extern fn ZString zlib_version() @cname("zlibVersion");
extern fn CInt deflate_init2(ZStream* strm, CInt level, CInt method, CInt window_bits, CInt mem_level,
                             CInt strategy, ZString version, CInt stream_size) @cname("deflateInit2_");
extern fn CInt inflate_init2(ZStream* strm, CInt window_bits, ZString version, CInt stream_size) @cname("inflateInit2_");
extern fn CInt deflate(ZStream* strm, CInt flush);
extern fn CInt inflate(ZStream* strm, CInt flush);
extern fn CInt deflate_end(ZStream* strm) @cname("deflateEnd");
extern fn CInt inflate_end(ZStream* strm) @cname("inflateEnd");
