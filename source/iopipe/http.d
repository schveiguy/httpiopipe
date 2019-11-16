/++
   Copyright ©2013-2017 Adam D. Ruppe.
   Copyright ©2018 Steven Schveighoffer

   This module uses ideas and code from arsd.http2 built on top of iopipe and
   std.io. It's not a direct port, as we are expecting those using the library
   to define how they want to use the io. All operations are assumed
   synchronous. If you want async support, you need to use an async driver for
   the io. See std.io for more details.
+/
module iopipe.http;

import iopipe.bufpipe;
import iopipe.textpipe;
import iopipe.valve;
import iopipe.traits;
import iopipe.zip;
import std.string;
import std.conv;


version = use_openssl;

struct Cookie
{
    string name;
    string value;
    // TODO: parse the directives and use them to direct behavior
    string[2][] directives;
}

Cookie parseCookie(string info) @safe pure
{
    import std.algorithm : splitter;

    Cookie result;
    auto items = info.splitter(';');
    // parse name and value
    assert(!items.empty);
    auto nvpair = items.front.strip.splitter('=');
    assert(!nvpair.empty);
    result.name = nvpair.front;
    nvpair.popFront;
    assert(!nvpair.empty);
    result.value = nvpair.front;
    nvpair.popFront;
    assert(nvpair.empty);

    // parse off each directive
    items.popFront;
    foreach(item; items)
    {
        string[2] directive;
        nvpair = item.strip.splitter('=');
        // ignore empty directives
        if(nvpair.empty)
            continue;
        directive[0] = nvpair.front;
        nvpair.popFront;
        directive[1] = nvpair.front;
        nvpair.popFront;
        assert(nvpair.empty); // should be a=b format, not a=b=x format.
        result.directives ~= directive;
    }

    return result;
}

// header information
struct HttpHeader
{
    int code;
    string codeText;
    string httpVersion;
    string statusLine;
    string location;
    string contentType;
    int contentLength;
    Cookie[] cookies;
    string[] rawHeaders; // headers before they were parsed
    string[2][] headers; // parsed well-formed headers

}

auto decodeChunks(Chain)(Chain chain) if (isIopipe!Chain && is(WindowType!Chain : const(ubyte[])))
{
    // chunks are defined as pieces of the original buffer. The least worst
    // way to process these is to rewrite the data as the chunked data
    // comes in. This means overwriting the data as it comes in to remove
    // the chunk markers. Because we don't have the ability to shrink the
    // end of the buffer, before we extend more data, we move everything
    // up that we have processed so far.
    //
    // If the data is const, however, we have to re-buffer, which makes
    // things straightforward. So this is the current implementation, I
    // will work on the fancier one later.
    static struct HTTPChunkSource
    {
        Chain chain;
        private size_t chunkRemaining;
        private bool eof;
        size_t read(ubyte[] buf)
        {
            import std.algorithm : min;
            import std.exception : enforce;
            import iopipe.bufpipe;
            // don't do a read if not necessary
            if(buf.length == 0)
                return 0;
            size_t result = 0;
            if(chunkRemaining == 0) // make sure there's enough to read a chunk header
                cast(void)chain.extend(0);
            while(chain.window.length > 0 && buf.length > 0)
            {
                if(chunkRemaining > 2)
                {
                    size_t nToRead = min(chunkRemaining - 2, chain.window.length, buf.length);
                    buf[0 .. nToRead] = chain.window[0 .. nToRead];
                    buf = buf[nToRead .. $];
                    chain.release(nToRead);
                    chunkRemaining -= nToRead;
                    result += nToRead;
                }
                else if(chunkRemaining == 2)
                {
                    auto window = chain.window;
                    // process the \r\n
                    if(window.length < 2)
                        return result;
                    enforce(window[0] == '\r' && window[1] == '\n', "expected carriage return newline sequence in chunked stream!");
                    chain.release(2);
                    chunkRemaining = 0;
                }
                else
                {
                    assert(chunkRemaining == 0);
                    if(eof)
                        return result;
                    auto window = chain.window;
                    size_t idx = 0;
                    size_t chunkSize = 0;
                    while(window[idx] != ';' && window[idx] != '\r')
                    {
                        immutable ch = window[idx];
                        if(ch >= '0' && ch <= '9')
                            chunkSize = (chunkSize << 4) | (ch - '0');
                        else if(ch >= 'a' && ch <= 'f')
                            chunkSize = (chunkSize << 4) | (ch - 'a' + 10);
                        else if(ch >= 'A' && ch <= 'F')
                            chunkSize = (chunkSize << 4) | (ch - 'A' + 10);
                        if(++idx == window.length)
                            // end of the window
                            return result;
                    }
                    while(window[idx] != '\r')
                        if(++idx == window.length)
                            // end of the window
                            return result;
                    if(++idx == window.length)
                        return result;
                    if(window[idx] != '\n')
                        throw new Exception("expected carriage return newline sequence in chunked stream!");
                    ++idx;
                    if(chunkSize == 0)
                    {
                        // final chunk
                        eof = true;
                    }
                    chunkRemaining = chunkSize + 2;
                    chain.release(idx);
                }
            }
            return result;
        }

        mixin implementValve!chain;
    }
    return HTTPChunkSource(chain).bufd!ubyte;
}

unittest
{
    // from wikipedia
    auto chunkedData = "4\r\nWiki\r\n5\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\n\r\n";
    auto chunkedPipe = (cast(immutable(ubyte)[])chunkedData).decodeChunks;
    chunkedPipe.ensureElems;
    assert(chunkedPipe.window == cast(ubyte[])"Wikipedia in\r\n\r\nchunks.");
}

// a pipe which stops after content-length bytes have been read.
auto contentPipe(Chain)(Chain chain, size_t contentLength = size_t.max - 1) if (isIopipe!Chain && is(WindowType!Chain : const(ubyte[])))
{
    static struct ContentPipe
    {
        private size_t remaining;
        Chain chain;

        ubyte[] window()
        {
            auto baseWin = chain.window;
            if(baseWin.length > remaining)
                baseWin = baseWin[0 .. remaining];
            return baseWin;
        }
        void release(size_t elems)
        {
            assert(elems <= remaining);
            chain.release(elems);
            remaining -= elems;
        }

        size_t extend(size_t elems)
        {
            size_t origLen = chain.window.length;
            if(origLen >= remaining)
                // no need to try reading more, we won't return it anyway
                return 0;
            auto result = chain.extend(elems);
            import std.algorithm : min;
            return min(remaining - origLen, result);
        }

        mixin implementValve!(chain);
    }

    return ContentPipe(contentLength, chain);
}

// a result from connecting to a server. Headers are poplulated by the time you
// get this, but the content is still streamed via the underlying pipe.
struct HttpPipe(BasePipe) if (isIopipe!BasePipe && is(WindowType!BasePipe : const(ubyte[])))
{
    import std.meta : AliasSeq;
    import taggedalgebraic : TaggedAlgebraic;

    // TODO, this really should just be const
    private HttpHeader _headers;
    ref const(HttpHeader) headers() const { return _headers; }


    private
    {
        alias ChunkedPipe = typeof(BasePipe.init.decodeChunks());
        alias ContentPipe = typeof(BasePipe.init.contentPipe());
        union Pipes
        {
            ContentPipe normal;
            typeof(unzip(ContentPipe.init)) compressed;
            ChunkedPipe chunked;
            typeof(unzip(ChunkedPipe.init)) chunkedCompressed;
        }
        TaggedAlgebraic!Pipes pipes;
        // if the window type is not ubyte[], then we need to use
        // const(ubyte)[] since the unzipped buffer must be mutable.
        static if(is(typeof(BasePipe.init.window()) == ubyte[]))
            ubyte[] _cachedWindow;
        else
            const(ubyte)[] _cachedWindow;
    }

    this(BasePipe stream)
    {
        import std.algorithm : splitter;
        // generate a resulting pipe based on the stream data.
        auto resultPipe = stream
            .simpleValve // Allow us to get back to the original buffered socket.
            .assumeText  // assume UTF-8 (ascii)
            .byLine;     // convert to lines

        cast(void)resultPipe.extend(0);
        // first line is the status line
        auto line = resultPipe.window.strip.idup;
        HttpHeader responseData;
        responseData.statusLine = line;
        auto parts = line.splitter;
        responseData.httpVersion = parts.front;
        parts.popFront;
        responseData.code = to!int(parts.front);
        parts.popFront;
        // parts.front now points at the codeText, but may have spaces, so just
        // use the pointer (unsafe!)
        // TODO use bufref library when finished.
        auto parsedOff = parts.front.ptr - line.ptr;
        responseData.codeText = parts.front.ptr[0 .. (line.length - parsedOff)];

        bool isChunked = false;
        bool isCompressed = false;
        CompressionFormat compFormat;

        // parse the remaining headers
        while(true)
        {
            // throw away the current line, parse the next one
            resultPipe.release(resultPipe.window.length);
            cast(void)resultPipe.extend(0);
            auto tmpline = resultPipe.window.strip;
            if(tmpline.length == 0)
                // end of headers
                break;
            line = tmpline.idup;
            responseData.rawHeaders ~= line;
            auto colon = line.indexOf(':');
            if(colon == -1)
                // not a well-formed header, don't worry about processing it.
                continue;

            auto name = line[0 .. colon];
            auto value = line[colon + 2 .. $]; // skipping the colon itself and the following space
            responseData.headers ~= cast(string[2])[name, value];
            switch(name) {
            case "Connection":
            case "connection":
                if(value == "close")
                {
                    // TODO: handle this somehow
                }
                break;
            case "Content-Type":
            case "content-type":
                responseData.contentType = value;
                break;
            case "Location":
            case "location":
                responseData.location = value;
                break;
            case "Content-Length":
            case "content-length":
                responseData.contentLength = to!int(value);
                break;
            case "Transfer-Encoding":
            case "transfer-encoding":
                // note that if it is gzipped, it zips first, then chunks the compressed stream.
                // so we should always dechunk first, then feed into the decompressor
                if(value == "chunked")
                    isChunked = true;
                else throw new Exception("Unknown Transfer-Encoding: " ~ value);
                break;
            case "Content-Encoding":
            case "content-encoding":
                if(value == "gzip") {
                    isCompressed = true;
                    compFormat = CompressionFormat.gzip;
                } else if(value == "deflate") {
                    isCompressed = true;
                    compFormat = CompressionFormat.deflate;
                } else throw new Exception("Unknown Content-Encoding: " ~ value);
                break;
            case "Set-Cookie":
            case "set-cookie":
                responseData.cookies ~= parseCookie(value);
                break;
            default:
                // ignore

            }
        }

        // make sure any lingering header data is out of the pipe
        resultPipe.release(resultPipe.window.length);

        // fetch the original socket, unwrapping all the text conversions and
        // line processing, and build the appropriate decoder on top of it.
        auto origSocket = resultPipe.valve;
        _headers = responseData;


        // deal with any encoding issues.
        if(isChunked)
        {
            if(isCompressed)
                pipes = origSocket.decodeChunks.unzip;
            else
                pipes = origSocket.decodeChunks;
        }
        else
        {
            // set up the content length if necessary
            auto content = origSocket.contentPipe(responseData.contentLength == 0 ?
                         size_t.max - 1 : responseData.contentLength);
            if(isCompressed)
                pipes = content.unzip;
            else
                pipes = content;
        }
        _cachedWindow = pipes.window;
    }

    static if(hasValve!BasePipe)
    {
        ref valve()
        {
            static assert(is(typeof(pipes.valve()) == PropertyType!(BasePipe.init.valve)));
            return pipes.valve;
        }
    }

    // cache the window since it's the most common function, and the underlying
    // window should always be the same.
    auto window()
    {
        return _cachedWindow;
    }

    void release(size_t elements)
    {
        pipes.release(elements);
        _cachedWindow = pipes.window;
    }

    size_t extend(size_t elements)
    {
        auto result = pipes.extend(elements);
        _cachedWindow = pipes.window;
        return result;
    }
}

// IFTI convenience function
auto httpPipe(Chain)(Chain chain)
{
    return HttpPipe!Chain(chain);
}

// test httpPipe
unittest
{
    import std.conv : to;
    enum htmldoc = "<html><head></head><body>Hello, World!</body>";
    auto response = cast(immutable(ubyte)[]) ("HTTP/1.1 404 Not Found\r\n" ~
        "Date: Tue, 27 Nov 2018 04:06:13 GMT\r\n" ~
        "Server: NoServer v1.0\r\n" ~
        "Content-Length: " ~ htmldoc.length.to!string ~ "\r\n" ~
        "Content-Type: text/html\r\n" ~
        "\r\n" ~ htmldoc);

    auto p = response.httpPipe;
    const h = p.headers;
    assert(h.code == 404);
    assert(h.codeText == "Not Found");
    assert(h.httpVersion == "HTTP/1.1");
    assert(h.statusLine == "HTTP/1.1 404 Not Found");
    assert(h.location == "");
    assert(h.contentType == "text/html");
    assert(h.contentLength == htmldoc.length);
    assert(p.window == cast(immutable(ubyte)[])htmldoc);
}

///
enum HttpVerb
{
    ///
    GET,
    ///
    HEAD,
    ///
    POST,
    ///
    PUT,
    ///
    DELETE,
    ///
    OPTIONS,
    ///
    TRACE,
    ///
    CONNECT,
    ///
    PATCH,
    ///
    MERGE
}


// Copy pasta from cgi.d, then stripped down
///
struct Uri
{
    alias toString this; // blargh idk a url really is a string, but should it be implicit?

    // scheme//userinfo@host:port/path?query#fragment

    string scheme; /// e.g. "http" in "http://example.com/"
    string userinfo; /// the username (and possibly a password) in the uri
    string host; /// the domain name
    int port; /// port number, if given. Will be zero if a port was not explicitly given
    string path; /// e.g. "/folder/file.html" in "http://example.com/folder/file.html"
    string query; /// the stuff after the ? in a uri
    string fragment; /// the stuff after the # in a uri.

    /// Breaks down a uri string to its components
    this(string uri) {
        reparse(uri);
    }

    private void reparse(string uri) {
        import std.regex;
        // from RFC 3986

        // the ctRegex triples the compile time and makes ugly errors for no real benefit
        // it was a nice experiment but just not worth it.
        // enum ctr = ctRegex!r"^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?";
        auto ctr = regex(r"^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?");

        auto m = match(uri, ctr);
        if(m) {
            scheme = m.captures[2];
            auto authority = m.captures[4];

            auto idx = authority.indexOf("@");
            if(idx != -1) {
                userinfo = authority[0 .. idx];
                authority = authority[idx + 1 .. $];
            }

            idx = authority.indexOf(":");
            if(idx == -1) {
                port = 0; // 0 means not specified; we should use the default for the scheme
                host = authority;
            } else {
                host = authority[0 .. idx];
                port = to!int(authority[idx + 1 .. $]);
            }

            path = m.captures[5];
            query = m.captures[7];
            fragment = m.captures[9];
        }
        // uriInvalidated = false;
    }

    private string rebuildUri() const {
        string ret;
        if(scheme.length)
            ret ~= scheme ~ ":";
        if(userinfo.length || host.length)
            ret ~= "//";
        if(userinfo.length)
            ret ~= userinfo ~ "@";
        if(host.length)
            ret ~= host;
        if(port)
            ret ~= ":" ~ to!string(port);

        ret ~= path;

        if(query.length)
            ret ~= "?" ~ query;

        if(fragment.length)
            ret ~= "#" ~ fragment;

        // uri = ret;
        // uriInvalidated = false;
        return ret;
    }

    /// Converts the broken down parts back into a complete string
    string toString() const {
        // if(uriInvalidated)
        return rebuildUri();
    }

    /// Returns a new absolute Uri given a base. It treats this one as
    /// relative where possible, but absolute if not. (If protocol, domain, or
    /// other info is not set, the new one inherits it from the base.)
    ///
    /// Browsers use a function like this to figure out links in html.
    Uri basedOn(in Uri baseUrl) const {
        Uri n = this; // copies
        // n.uriInvalidated = true; // make sure we regenerate...

        // userinfo is not inherited... is this wrong?

        // if anything is given in the existing url, we don't use the base anymore.
        if(n.scheme.empty) {
            n.scheme = baseUrl.scheme;
            if(n.host.empty) {
                n.host = baseUrl.host;
                if(n.port == 0) {
                    n.port = baseUrl.port;
                    if(n.path.length > 0 && n.path[0] != '/') {
                        auto b = baseUrl.path[0 .. baseUrl.path.lastIndexOf("/") + 1];
                        if(b.length == 0)
                            b = "/";
                        n.path = b ~ n.path;
                    } else if(n.path.length == 0) {
                        n.path = baseUrl.path;
                    }
                }
            }
        }

        return n;
    }
}

struct HttpQueryParameters
{
}

version(use_openssl)
{
    import core.stdc.stdio;
    extern(C) {
        int SSL_library_init();
        void OpenSSL_add_all_ciphers();
        void OpenSSL_add_all_digests();
        void SSL_load_error_strings();

        struct SSL {}
        struct SSL_CTX {}
        struct SSL_METHOD {}

        SSL_CTX* SSL_CTX_new(const SSL_METHOD* method);
        SSL* SSL_new(SSL_CTX*);
        int SSL_set_fd(SSL*, int);
        int SSL_connect(SSL*);
        int SSL_write(SSL*, const void*, int);
        int SSL_read(SSL*, void*, int);
        void SSL_free(SSL*);
        void SSL_CTX_free(SSL_CTX*);

        int SSL_pending(const SSL*);

        void SSL_set_verify(SSL*, int, void*);
        enum SSL_VERIFY_NONE = 0;

        SSL_METHOD* SSLv3_client_method();
        SSL_METHOD* TLS_client_method();
        SSL_METHOD* SSLv23_client_method();

        void ERR_print_errors_fp(FILE*);
    }

    shared static this() {
        SSL_library_init();
        OpenSSL_add_all_ciphers();
        OpenSSL_add_all_digests();
        SSL_load_error_strings();
    }


    // hack at this point to pair a socket with an SSL channel
    // Note that the constructor expects a connected socket.

    // TODO: use vibe.d technique to wrap the BIO interface with a buffered
    // stream. Need to investigate how it works.
    struct OpenSslSocket
    {
        import std.io.net.socket;
        private
        {
            Socket sock;
            SSL* ssl;
            SSL_CTX* ctx;
            // this is so ugly, but have not choice right now
            auto sockFD()
            {
                version(Posix)
                {
                    return *cast(int*)&sock;
                }
                else
                {
                    assert(false, "Unsupported");
                }
            }
            void initSsl(bool verifyPeer)
            {
                ctx = SSL_CTX_new(SSLv23_client_method());
                assert(ctx !is null);

                ssl = SSL_new(ctx);
                if(!verifyPeer)
                    SSL_set_verify(ssl, SSL_VERIFY_NONE, null);
                SSL_set_fd(ssl, sockFD);
                if(SSL_connect(ssl) == -1)
                    throw new Exception("ssl connect");
            }
        }

        @trusted size_t write(const(ubyte)[] buf)
        {
            auto retval = SSL_write(ssl, buf.ptr, cast(uint) buf.length);
            if(retval < 0) {
                ERR_print_errors_fp(core.stdc.stdio.stdout);
                throw new Exception("ssl write");
            }
            return retval;
        }

        @trusted size_t read(ubyte[] buf)
        {
            auto retval = SSL_read(ssl, buf.ptr, cast(uint) buf.length);
            if(retval < 0) {
                throw new Exception("ssl read");
            }
            return retval;
        }

        this(Socket sock)
        {
            // TODO: use std.algorithm.move
            this.sock = sock.move;
            initSsl(true);
        }

        ~this() {
            if(ssl !is null)
            {
                SSL_free(ssl);
                ssl = null;
            }
            if(ctx !is null)
            {
                SSL_CTX_free(ctx);
                ctx = null;
            }
            // sock will close the fd.
        }
    }
}
 
/// HttpClient keeps cookies, location, and some other state to reuse connections, when possible, like a web browser.
class HttpClient
{
    import std.io.net.socket;
    /* Protocol restrictions, useful to disable when debugging servers */
    bool useHttp11 = true; ///
    bool acceptGzip = true; ///

    /// Automatically follow a redirection?
    bool followLocation = false; /// NOT IMPLEMENTED

    ///
    @property Uri location() {
        return currentUrl;
    }

    /// High level function that works similarly to entering a url
    /// into a browser.
    ///
    /// Follows locations, updates the current url.
    auto navigateTo(Uri where, HttpVerb method = HttpVerb.GET,
                        HttpQueryParameters parameters = HttpQueryParameters.init)
    {
        currentUrl = where.basedOn(currentUrl);
        currentDomain = where.host;

        return request(where, method, parameters);
    }

    private auto setupRequest(BufferedInputPipe)(BufferedInputPipe pipe, Uri where, HttpVerb method, HttpQueryParameters parameters)
    {
        // fetch the actual socket from the buffered input pipe
        auto sock = pipe.dev;
        // got a socket, need to send the request parameters
        //
        // set up a local buffer for writing, we only need it temporarily
        ubyte[4096] buf;
        //auto requestBuffer = buf[].lbufd!(char, buf.length)
        auto requestBuffer = bufd!(char)
            .push!(a => a.encodeText.outputPipe(sock), false);

        // write header data to the socket
        void hdr(const(char)[][] data...)
        {
            foreach(d; data)
            {
                auto written = requestBuffer.writeBuf(d);
                // TODO: really should be an exception
                assert(written == d.length);
            }
        }

        hdr(method.to!string, " ", where.path.length ? where.path : "/");
        if(where.query.length)
            hdr("?", where.query);


        if(useHttp11)
            hdr(" HTTP/1.1\r\n");
        else
            hdr(" HTTP/1.0\r\n");

        hdr("Host: ", where.host, "\r\n");

        if(userAgent.length)
            hdr("User-Agent: ", userAgent, "\r\n");

        if(authorization.length)
            hdr("Authorization: ", authorization, "\r\n");

        if(acceptGzip)
            hdr("Accept-Encoding: gzip\r\n");

        // tell the server we may add more items.
        hdr("Connection: keep-alive\r\n");

        hdr("\r\n");

        // make sure all data gets sent
        requestBuffer.flush();

        return pipe.simpleValve.httpPipe;
    }

    auto request(Uri where, HttpVerb method = HttpVerb.GET,
                        HttpQueryParameters parameters = HttpQueryParameters.init)
    {

        import std.typecons : refCounted;

        auto sock = openConnection(where.host, false, cast(short)where.port).refCounted;
        return setupRequest(sock.bufd, where, method, parameters);
    }

    version(use_openssl)
        auto requestSSL(Uri where, HttpVerb method = HttpVerb.GET,
                        HttpQueryParameters parameters = HttpQueryParameters.init)
        {

            import std.typecons : refCounted;

            auto sock = OpenSslSocket(openConnection(where.host, true, cast(short)where.port)).refCounted;
            auto req = setupRequest(sock.bufd, where, method, parameters);
            return  req;
        }

    // reuse an existing http socket object to send a new request (using keepalive)
    auto request(Chain)(ref Chain c, Uri where, HttpVerb method = HttpVerb.GET,
                        HttpQueryParameters parameters = HttpQueryParameters.init)
    {
        // get the original buffered socket
        auto bufferedSock = c.valveOf!BufferedInputSource;
        return setupRequest(bufferedSock, where, method, parameters);
    }

    private Socket openConnection(string hostname, bool ssl = false, short port = 0)
    {
        version(use_openssl)
        {
        }
        else
            assert(!ssl);
        auto result = Socket(ProtocolFamily.IPv4, SocketType.stream);
        // determine the host ipaddr, based on name service
        import std.io.driver;
        import std.io.net;
        auto rc = driver.resolve(hostname ~ '\0', ssl ? "https" : "http", AddrFamily.IPv4, SocketType.stream, Protocol.default_, (ref scope ai) {
              // set the port according to the parameter
              auto addr4 = ai.addr.get!SocketAddrIPv4;
              if(port != 0)
                  addr4.port = port;
              result.connect(addr4);
              return 1;
          });
        if(rc != 1)
            throw new Exception("Cannot resolve host: " ~ hostname);
        return result.move;
    }

    /++
        Creates a request without updating the current url state
        (but will still save cookies btw)

        +/
        /*HttpRequest request(Uri uri, HttpVerb method = HttpVerb.GET, ubyte[] bodyData = null, string contentType = null) {
            auto request = new HttpRequest(uri, method);

            request.requestParameters.userAgent = userAgent;
            request.requestParameters.authorization = authorization;

            request.requestParameters.useHttp11 = this.useHttp11;
            request.requestParameters.acceptGzip = this.acceptGzip;

            request.requestParameters.bodyData = bodyData;
            request.requestParameters.contentType = contentType;

            return request;

        }

    /// ditto
    HttpRequest request(Uri uri, FormData fd, HttpVerb method = HttpVerb.POST) {
        return request(uri, method, fd.toBytes, fd.contentType);
    }*/


    private Uri currentUrl;
    private string currentDomain;

    void setCookie(string domain, string name, string value)
    {
        Cookie c;
        c.name = name;
        c.value = value;
        setCookie(domain, c);
    }

    void setCookie(string domain, ref Cookie c)
    {
        if(auto arr = domain in cookies)
        {
            // see if the cookie already exists
            foreach(ref cookie; *arr)
            {
                if(cookie.name == c.name)
                {
                    // update the cookie with the new data
                    cookie = c;
                    return;
                }
            }
            // not in the array
            *arr ~= c;
        }
        else
        {
            // no cookies for this domain yet
            cookies[domain] = [c];
        }
    }

    void clearCookies(string domain = null) {
        if(domain is null)
            cookies.clear;
        else
            cookies[domain] = null;
    }

    // If you set these, they will be pre-filled on all requests made with this client
    string userAgent = "D iopipe.html"; ///
    string authorization; ///

    /* inter-request state */
    Cookie[][string] cookies;
}
