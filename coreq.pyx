# Copyright (c) 2015, Mike Taghavi (mitghi) <mitghi@me.com>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# * Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
#
# * Redistributions in binary form must reproduce the above copyright notice,
#	  this list of conditions and the following disclaimer in the documentation
#	  and/or other materials provided with the distribution.
#
#	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
#	AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
#	IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
#	DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
#	FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
#	DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
#	SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
#	CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
#	OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
#	OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


import select
import socket
import ssl


cdef class _result:
	cdef public str result
	cdef public str header
	cdef public unsigned short short int status
	cdef public str _raw 
	def __cinit__(self, str result, unsigned short short int status):
		self._raw = result
		self.result = self.eval(result)		
		self.status = <unsigned short short int>status

	cpdef eval(self,str result):
		cdef list body = []
		self.header = ""
		
		if result:
			body = result.split("\r\n\r\n",1)
			self.header = body[0]
			return ''.join(body[1:])
		return ''
	
class Result(Exception):
	def __init__(self,result, track):
		self.result = result
		self.track = track

cdef class coro:
	cdef dict seeds 
	cdef object eventloop
	cdef bint stop_cond
	cdef str useragent
	cdef public dict results
	cdef list stack
	def __cinit__(self, dict seeds, str useragent=""):
		self.seeds = seeds
		self.eventloop = self._event_loop()
		self.stop_cond = 0
		self.useragent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.11; rv:42.0) Gecko/20100101 Firefox/42.0' if useragent == "" else useragent
		self.stack = []
		self.results = {}
		
	cdef inline object _create_sock(self):
		cdef object sock = socket.socket(socket.AF_INET,socket.SOCK_STREAM)
		sock.setsockopt(socket.SOL_SOCKET,socket.TCP_NODELAY,1)
		sock.setblocking(0)

		return sock

	def _read_sock(self,object sock, str track, bint debug=False):
		cdef list got = []
		cdef str res = ""
		while True:
			try:
				res = sock.recv(165535)
				if debug: print 'reading from{}'.format(track)
				if not res: break
				got.append(res)
				yield
			except ssl.SSLError: pass
			except Exception: pass

		self._terminate_sock(sock)
		raise Result(''.join(got),track)

	cdef inline void _terminate_sock(self,object sock):
		try:
			sock.shutdown()
			sock.close()
		except Exception: pass

	def _event_loop(self):	
		cdef dict input = self.seeds.copy()
		cdef dict cs = {}
		cdef dict track = {}
		cdef int read_only = select.EPOLLIN | select.EPOLLPRI | select.EPOLLHUP | select.EPOLLERR
		cdef int read_write = read_only | select.EPOLLOUT
		cdef object epoll = select.epoll()
		cdef object sock
		cdef object events

		for i in input.keys():
			sock = self._create_sock()
			cs[sock.fileno()] = [sock,self.seeds[i][1],self.seeds[i][2]]
			track[sock.fileno()] = i
			epoll.register(cs[sock.fileno()][0],read_write)
			try:
				cs[sock.fileno()][0].connect((self.seeds[i][0],self.seeds[i][1]))
			except socket.error: pass

		while True:
			if not cs: break
			events = epoll.poll(1)
			for fileno,event in events:
				if <int>event == <int>select.EPOLLOUT:
					if not isinstance(cs[fileno][0],ssl.SSLSocket) and cs[fileno][1]  == 443:
						cs[fileno][0] = ssl.wrap_socket(cs[fileno][0],do_handshake_on_connect=False)
					if isinstance(cs[fileno][0],ssl.SSLSocket):
						while True:
							try:
								cs[fileno][0].do_handshake()
								cs[fileno][0].write(self.genhttp_request(track[fileno],cs[fileno][2]))
								epoll.modify(fileno,read_only)
								break
							except ssl.SSLError: pass
					else:
						cs[fileno][0].sendall(self.genhttp_request(track[fileno],cs[fileno][2]))
						epoll.modify(fileno,read_only)

				elif <int>event == <int>select.EPOLLIN:
					yield cs[fileno][0], track[fileno]
					del cs[fileno]

				elif <int>event == <int>select.EPOLLERR:
					epoll.unregister(fileno)
					del cs[fileno]

				elif <int>event == <int>select.EPOLLERR | select.EPOLLOUT | select.EPOLLHUP | select.EPOLLIN:
					epoll.unregister(fileno)
					self._terminate_sock(cs[fileno])
					yield "failed", track[fileno]
					del cs[fileno]


	cdef str genhttp_request(self, str target,str path):
		req = [
			"GET /{} HTTP/1.1\r\n",
			"Host: {}\r\n",
			"User-Agent: {}\r\n",
			"Connection: Close\r\n\r\n"
		]

		return ''.join(req).format(path,target,self.useragent)


	cpdef void _start(self, bint stop_cond=0):
		cdef:
			object sock
			object track
			object _next
			
		while True:
			try:
				if self.eventloop:
					sock, track = self.eventloop.next()
					if isinstance(sock, ssl.SSLSocket) or isinstance(sock, socket._socketobject):
						self.stack.append(self._read_sock(sock,track))
					elif isinstance(sock, str):
						self.results.update({track:_result("",1)})
			except StopIteration: self.eventloop = None ; pass
			for item, _ in enumerate(self.stack):
				try:
					_next = self.stack[item].next()
				except StopIteration: pass
				except Result,r:
					self.results.update({r.track: _result(r.result,0)})

			if len(self.seeds) == len(self.results): break
	
	def __call__(self):
		self._start()
		return self
	
	def __enter__(self):
		self()
		return self.results

	def __exit__(self, type, value, traceback):
		pass
