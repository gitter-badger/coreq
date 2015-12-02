# coreq

Very small HTTP client written in Cython. Both HTTP and HTTPS are supported.
Currently it uses Epoll. Redirection, chunked parsing and caching are not implemented in this version. 

# Examples
coreq.coro takes a dictionary and items must have the following format: 
    
  website : ( ip/website , port , page )

    with coreq.coro({'www.python.org':('www.python.org',443,"") , 'www.reddit.com':('198.41.208.138', 443, 'r/marketing') }) as e:
      	print e.keys()
      	print e.get("www.python.org").header
      	print e.get("www.python.org").result
