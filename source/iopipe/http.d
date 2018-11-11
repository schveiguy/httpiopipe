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
import iopipe.zip;

enum Channel : ubyte
{
    normal,
    compressed,
    chunked,
    chunkedCompressed
}


// a result from connecting to a server. Headers are poplulated by the time you
// get this, but the content is still streamed via the underlying pipe.
struct HttpPipe(BasePipe) if (isIopipe!BasePipe && is(WindowType!BasePipe == ubyte[]))
{
    private HttpHeader _headers;
    HttpClient client;
    ref const(HttpHeader) headers() const { return _headers; }

    private alias ChunkedPipe = typeof(BasePipe.init.httpChunkPipe());

    private alias PipeTypes = AliasSeq!(
           BasePipe,
           typeof(unzip(BasePipe.init)),
           ChunkedPipe,
           typeof(unzip(ChunkedPipe.init))
           );

    private union
    {
        PipeTypes pipes;
    }

    private Channel channel;
    private ubyte[] _cachedwindow;

    static if(hasValve!BasePipe)
    {
        ref valve()
        {
            final switch(channel)
            {
                static foreach(i; 0 .. PipeTypes.length)
                {
                case cast(Channel)i:
                    return pipes[i].valve;
                }
            }
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
outer:
        final switch(channel)
        {
            static foreach(i; 0 .. PipeTypes.length)
            {
            case cast(Channel)i:
                pipes[i].release(elements);
                _cachedWindow = pipes[i].window;
                break outer;
            }
        }
    }

    size_t extend(size_t elements)
    {
        size_t result;
outer:
        final switch(channel)
        {
            static foreach(i; 0 .. PipeTypes.length)
            {
            case cast(Channel)i:
                result = pipes[i].extend(elements);
                _cachedWindow = pipes[i].window;
                break outer;
            }
        }
        return result;
    }
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
 
/// HttpClient keeps cookies, location, and some other state to reuse connections, when possible, like a web browser.
class HttpClient
{
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

    HttpRequest request(Uri where, HttpVerb method = HttpVerb.GET,
                        HttpQueryParameters parameters = HttpQueryParameters.init)
    {

        auto sock = openConnection(where.host, where.port, where.scheme == "https").refCounted;

        // got a socket, need to send the request parameters
        auto requestBuffer = bufd!char.push!(a => a.outputPipe(sock), false);

        // write header data to the socket
        void hdr(const(char)[][] data...)
        {
            foreach(d; data)
            {
                while(d.length)
                {
                    const dlen = d.length;
                    if(requestBuffer.window.length == 0)
                        requestBuffer.extend(0);
                    const wlen = requestBuffer.window.length;
                    // TODO: really should be an exception
                    assert(wlen > 0);
                    if(wlen > dlen)
                    {
                        requestBuffer.window[0 .. dlen] = d;
                        requestBuffer.release(dlen);
                        break;
                    }
                    else
                    {
                        requestBuffer.window[] = d[0 .. wlen];
                        d = d[wlen .. $];
                        requestBuffer.release(wlen);
                    }
                }
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

        if(acceptGzip)
            hdr("Accept-Encoding: gzip\r\n");

        // make sure all data gets sent
        requestBuffer.flush();

        // now, generate a resulting pipe based on the response data.
        auto resultPipe = sock
            .bufd        // buffer it
            .simpleValve // Allow us to get back to the original buffered socket.
            .assumeText  // assume UTF-8 (ascii)
            .byLinePipe; // convert to lines

        resultPipe.extend(0);
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
            resultPipe.release(resultPipe.window);
            resultPipe.extend(0);
            line = resultPipe.window.strip.dup;
            responseData.headers ~= line;
            auto colon = header.indexOf(':');
            if(colon == -1)
                // not a well-formed header, don't worry about processing it.
                continue;

            auto name = line[0 .. colon];
            auto value = line[colon + 2 .. $]; // skipping the colon itself and the following space
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
                responseData.contentLengthRemaining = to!int(value);
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
                // FIXME handle
                break;
            default:
                // ignore

            }
        }

        // fetch the original socket, unwrapping all the text conversions, and
        // unzip if necessary.
        auto origSocket = resultPipe.valve;
        auto pipe = HttpPipe!(typeof(origSocket));
        pipe.headers = responseData;

        // deal with any encoding issues.
        if(isChunked)
        {
            assert(false); // not implemented yet.
        }
        else
        {
            if(isCompressed)
            {
                pipe.pipes[Channel.compressed] = origSocket.unzip;
            }
            else
            {
                pipe.pipes[Channel.normal] = origSocket;
            }
        }
        return HttpPipe!(typeof(origSocket))(origSocket);
    }

    private Socket openConnection(string hostname, int port, bool ssl)
    {
        // no support for ssl yet
        assert(!ssl);
    }


    /++
        Creates a request without updating the current url state
        (but will still save cookies btw)

        +/
        HttpRequest request(Uri uri, HttpVerb method = HttpVerb.GET, ubyte[] bodyData = null, string contentType = null) {
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
    }


    private Uri currentUrl;
    private string currentDomain;

    this(ICache cache = null) {

    }

    // FIXME: add proxy
    // FIXME: some kind of caching

    ///
    void setCookie(string name, string value, string domain = null) {
        if(domain == null)
            domain = currentDomain;

        cookies[domain][name] = value;
    }

    ///
    void clearCookies(string domain = null) {
        if(domain is null)
            cookies = null;
        else
            cookies[domain] = null;
    }

    // If you set these, they will be pre-filled on all requests made with this client
    string userAgent = "D arsd.html2"; ///
    string authorization; ///

    /* inter-request state */
    string[string][string] cookies;
}


