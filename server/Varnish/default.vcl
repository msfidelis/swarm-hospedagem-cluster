vcl 4.0;

import std;
import directors;

# COLOQUE OS BACKENDS AQUI

backend blog1 { 
  .host = "blog1";    
  .port = "80";           
  .max_connections = 300; 

  .probe = {

    .request =
      "HEAD / HTTP/1.1"
      "Host: localhost"
      "Connection: close"
      "User-Agent: Varnish Health Probe";

    #CHECA A SA�DE DO HOST  
    .interval  = 5s; 
    .timeout   = 1s; 
    .window    = 5;  
    .threshold = 3;
  }

  .first_byte_timeout     = 300s;   
  .connect_timeout        = 5s;     
  .between_bytes_timeout  = 2s;    
}



backend blog2 { 
  .host = "blog2";    
  .port = "80";           
  .max_connections = 300; 

  .probe = {

    .request =
      "HEAD / HTTP/1.1"
      "Host: localhost"
      "Connection: close"
      "User-Agent: Varnish Health Probe";

    #CHECA A SA�DE DO HOST  
    .interval  = 5s; 
    .timeout   = 1s; 
    .window    = 5;  
    .threshold = 3;
  }

  .first_byte_timeout     = 300s;   
  .connect_timeout        = 5s;     
  .between_bytes_timeout  = 2s;    
}

# ACL's n�o ser�o aplicadas
acl purge {
  "localhost";
  "127.0.0.1";
  "::1";
}

#Chama quando o VCL � carregado. Todos os requests passam por aqui antes de qualquer coisa
sub vcl_init {
  new vdir = directors.round_robin();

  # ADICIONAR OS BACKENDS CRIADOS AQUI
  vdir.add_backend(blog1);
  vdir.add_backend(blog2);
}

# Chamado depois que o request � parseado. Aqui aplicamos as regras de cacheamento. 
sub vcl_recv {

  //set req.backend_hint = vdir.backend(); 

  # DEFINE OS BACKENDS
  if (req.http.host ~ "local.blog1.com") {
      set req.backend_hint = blog1;
  } elsif (req.http.host ~ "local.blog2.com") {
      set req.backend_hint = blog2;
  }

  set req.http.Host = regsub(req.http.Host, ":[0-9]+", "");
  unset req.http.proxy;

  set req.url = std.querysort(req.url);


  if (req.method == "PURGE") {
    if (!client.ip ~ purge) {
      return (synth(405, "This IP is not allowed to send PURGE requests."));
    }
    return (purge);
  }

  if (req.method != "GET" &&
      req.method != "HEAD" &&
      req.method != "PUT" &&
      req.method != "POST" &&
      req.method != "TRACE" &&
      req.method != "OPTIONS" &&
      req.method != "PATCH" &&
      req.method != "DELETE") {
    /* Non-RFC2616 or CONNECT which is weird. */
    return (pipe);
  }

  # Web Socket Support - Testando pra fazer o Health Check funcionar
  if (req.http.Upgrade ~ "(?i)websocket") {
    return (pipe);
  }

  # Somente cachear requests GET - N�o implementado pela for�a do caga�o 
  #if (req.method != "GET" && req.method != "HEAD") {
  #  return (pass);
  #}

  if (req.url ~ "(\?|&)(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=") {
    set req.url = regsuball(req.url, "&(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "");
    set req.url = regsuball(req.url, "\?(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "?");
    set req.url = regsub(req.url, "\?&", "?");
    set req.url = regsub(req.url, "\?$", "");
  }

  # Hash
  if (req.url ~ "\#") {
    set req.url = regsub(req.url, "\#.*$", "");
  }

  # Strip a trailing ? if it exists
  if (req.url ~ "\?$") {
    set req.url = regsub(req.url, "\?$", "");
  }

  # Some generic cookie manipulation, useful for all templates that follow
  # Remove the "has_js" cookie
  set req.http.Cookie = regsuball(req.http.Cookie, "has_js=[^;]+(; )?", "");

  # Libera o Google Analytics do Cache - Cookies
  set req.http.Cookie = regsuball(req.http.Cookie, "__utm.=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "_ga=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "_gat=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "utmctr=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "utmcmd.=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "utmccn.=[^;]+(; )?", "");

  set req.http.Cookie = regsuball(req.http.Cookie, "__gads=[^;]+(; )?", "");

  set req.http.Cookie = regsuball(req.http.Cookie, "__qc.=[^;]+(; )?", "");

  set req.http.Cookie = regsuball(req.http.Cookie, "__atuv.=[^;]+(; )?", "");

  set req.http.Cookie = regsuball(req.http.Cookie, "^;\s*", "");

  if (req.http.cookie ~ "^\s*$") {
    unset req.http.cookie;
  }

  if (req.http.Cache-Control ~ "(?i)no-cache") {

    if (! (req.http.Via || req.http.User-Agent ~ "(?i)bot" || req.http.X-Purge)) {
      #set req.hash_always_miss = true; # Doesn't seems to refresh the object in the cache
      return(purge); # Couple this with restart in vcl_purge and X-Purge header to avoid loops
    }
  }

  # N�o cacheia arquivos grandes. 
  if (req.url ~ "^[^?]*\.(7z|avi|bz2|flac|flv|gz|mka|mkv|mov|mp3|mp4|mpeg|mpg|ogg|ogm|opus|rar|tar|tgz|tbz|txz|wav|webm|xz|zip)(\?.*)?$") {
    unset req.http.Cookie;
    return (hash);
  }

  # Remove all cookies for static files
  # A valid discussion could be held on this line: do you really need to cache static files that don't cause load? Only if you have memory left.
  # Sure, there's disk I/O, but chances are your OS will already have these files in their buffers (thus memory).
  # Before you blindly enable this, have a read here: https://ma.ttias.be/stop-caching-static-files/
  if (req.url ~ "^[^?]*\.(7z|avi|bmp|bz2|css|csv|doc|docx|eot|flac|flv|gif|gz|ico|jpeg|jpg|js|less|mka|mkv|mov|mp3|mp4|mpeg|mpg|odt|otf|ogg|ogm|opus|pdf|png|ppt|pptx|rar|rtf|svg|svgz|swf|tar|tbz|tgz|ttf|txt|txz|wav|webm|webp|woff|woff2|xls|xlsx|xml|xz|zip)(\?.*)?$") {
    unset req.http.Cookie;
    return (hash);
  }

  # Send Surrogate-Capability headers to announce ESI support to backend
  set req.http.Surrogate-Capability = "key=ESI/1.0";

  if (req.http.Authorization) {
    # Not cacheable by default
    return (pass);
  }

  return (hash);
}

sub vcl_pipe {

  # Implementing websocket support (https://www.varnish-cache.org/docs/4.0/users-guide/vcl-example-websockets.html)
  if (req.http.upgrade) {
    set bereq.http.upgrade = req.http.upgrade;
  }

  return (pipe);
}

sub vcl_pass {
  # Called upon entering pass mode. In this mode, the request is passed on to the backend, and the
  # backend's response is passed on to the client, but is not entered into the cache. Subsequent
  # requests submitted over the same client connection are handled normally.

  # return (pass);
}

sub vcl_hash {

  # Hashing dos dados do request
  hash_data(req.url);

  if (req.http.host) {
    hash_data(req.http.host);
  } else {
    hash_data(server.ip);
  }

  if (req.http.Cookie) {
    hash_data(req.http.Cookie);
  }
}

# Chama caso o Lookup dos dados seja Success
sub vcl_hit {

  if (obj.ttl >= 0s) {
    return (deliver);
  }


# if (!std.healthy(req.backend_hint) && (obj.ttl + obj.grace > 0s)) {
#   return (deliver);
# } else {
#   return (fetch);
# }

  # We have no fresh fish. Lets look at the stale ones.
  if (std.healthy(req.backend_hint)) {
    # Backend is healthy. Limit age to 10s.
    if (obj.ttl + 10s > 0s) {
      #set req.http.grace = "normal(limited)";
      return (deliver);
    } else {
      # No candidate for grace. Fetch a fresh object.
      return(fetch);
    }
  } else {
    # backend is sick - use full grace
      if (obj.ttl + obj.grace > 0s) {
      #set req.http.grace = "full";
      return (deliver);
    } else {
      # no graced object.
      return (fetch);
    }
  }

  # fetch & deliver once we get the result
  return (fetch); # Dead code, keep as a safeguard
}

sub vcl_miss {
  # Called after a cache lookup if the requested document was not found in the cache. Its purpose
  # is to decide whether or not to attempt to retrieve the document from the backend, and which
  # backend to use.

  return (fetch);
}

# Handle the HTTP request coming from our backend
sub vcl_backend_response {
  # Called after the response headers has been successfully retrieved from the backend.

  # Pause ESI request and remove Surrogate-Control header
  if (beresp.http.Surrogate-Control ~ "ESI/1.0") {
    unset beresp.http.Surrogate-Control;
    set beresp.do_esi = true;
  }

  # Enable cache for all static files
  # The same argument as the static caches from above: monitor your cache size, if you get data nuked out of it, consider giving up the static file cache.
  # Before you blindly enable this, have a read here: https://ma.ttias.be/stop-caching-static-files/
  if (bereq.url ~ "^[^?]*\.(7z|avi|bmp|bz2|css|csv|doc|docx|eot|flac|flv|gif|gz|ico|jpeg|jpg|js|less|mka|mkv|mov|mp3|mp4|mpeg|mpg|odt|otf|ogg|ogm|opus|pdf|png|ppt|pptx|rar|rtf|svg|svgz|swf|tar|tbz|tgz|ttf|txt|txz|wav|webm|webp|woff|woff2|xls|xlsx|xml|xz|zip)(\?.*)?$") {
    unset beresp.http.set-cookie;
  }

  # Large static files are delivered directly to the end-user without
  # waiting for Varnish to fully read the file first.
  # Varnish 4 fully supports Streaming, so use streaming here to avoid locking.
  if (bereq.url ~ "^[^?]*\.(7z|avi|bz2|flac|flv|gz|mka|mkv|mov|mp3|mp4|mpeg|mpg|ogg|ogm|opus|rar|tar|tgz|tbz|txz|wav|webm|xz|zip)(\?.*)?$") {
    unset beresp.http.set-cookie;
    set beresp.do_stream = true;  # Check memory usage it'll grow in fetch_chunksize blocks (128k by default) if the backend doesn't send a Content-Length header, so only enable it for big objects
  }

  # Sometimes, a 301 or 302 redirect formed via Apache's mod_rewrite can mess with the HTTP port that is being passed along.
  # This often happens with simple rewrite rules in a scenario where Varnish runs on :80 and Apache on :8080 on the same box.
  # A redirect can then often redirect the end-user to a URL on :8080, where it should be :80.
  # This may need finetuning on your setup.
  #
  # To prevent accidental replace, we only filter the 301/302 redirects for now.
  if (beresp.status == 301 || beresp.status == 302) {
    set beresp.http.Location = regsub(beresp.http.Location, ":[0-9]+", "");
  }

  # Set 2min cache if unset for static files
  if (beresp.ttl <= 0s || beresp.http.Set-Cookie || beresp.http.Vary == "*") {
    set beresp.ttl = 120s; # Important, you shouldn't rely on this, SET YOUR HEADERS in the backend
    set beresp.uncacheable = true;
    return (deliver);
  }

  # Don't cache 50x responses
  if (beresp.status == 500 || beresp.status == 502 || beresp.status == 503 || beresp.status == 504) {
    return (abandon);
  }

  # Allow stale content, in case the backend goes down.
  # make Varnish keep all objects for 6 hours beyond their TTL
  set beresp.grace = 6h;

  return (deliver);
}

# The routine when we deliver the HTTP request to the user
# Last chance to modify headers that are sent to the client
sub vcl_deliver {
  # Called before a cached object is delivered to the client.

  if (obj.hits > 0) { # Add debug header to see if it's a HIT/MISS and the number of hits, disable when not needed
    set resp.http.X-Cache = "HIT";
  } else {
    set resp.http.X-Cache = "MISS";
  }

  # Please note that obj.hits behaviour changed in 4.0, now it counts per objecthead, not per object
  # and obj.hits may not be reset in some cases where bans are in use. See bug 1492 for details.
  # So take hits with a grain of salt
  set resp.http.X-Cache-Hits = obj.hits;

  # Remove some headers: PHP version
  unset resp.http.X-Powered-By;

  # Remove some headers: Apache version & OS
  unset resp.http.Server;
  unset resp.http.X-Drupal-Cache;
  unset resp.http.X-Varnish;
  unset resp.http.Via;
  unset resp.http.Link;
  unset resp.http.X-Generator;

  return (deliver);
}

sub vcl_purge {
  # Only handle actual PURGE HTTP methods, everything else is discarded
  if (req.method != "PURGE") {
    # restart request
    set req.http.X-Purge = "Yes";
    return(restart);
  }
}

sub vcl_synth {
  if (resp.status == 720) {
    # We use this special error status 720 to force redirects with 301 (permanent) redirects
    # To use this, call the following from anywhere in vcl_recv: return (synth(720, "http://host/new.html"));
    set resp.http.Location = resp.reason;
    set resp.status = 301;
    return (deliver);
  } elseif (resp.status == 721) {
    # And we use error status 721 to force redirects with a 302 (temporary) redirect
    # To use this, call the following from anywhere in vcl_recv: return (synth(720, "http://host/new.html"));
    set resp.http.Location = resp.reason;
    set resp.status = 302;
    return (deliver);
  }

  return (deliver);
}


sub vcl_fini {
  # Called when VCL is discarded only after all requests have exited the VCL.
  # Typically used to clean up VMODs.

  return (ok);
}