

Merv/PortServer.hs - exports a single function createTCPPortListener

	This sets up threads to listen on incoming socket connections.
	The function expects IRC Messages, but other protocols could
        be embeded or the function generalized to work with any 
        tcp protocol.

Merv/Multiplex.hs - exports multiplexChildPost

	Set up threads which 
		* read from an input queue, 
                * react to the input,
                * translate it in some way, 
                * and then forward to output queue
	
Merv/Log.hs -  provides log, logf, withGlobalLogging

	Set up global logging thread, and provide
        convenient log related functions.

InteruptableDelay.hs - interface interupt a specific threadDelay
	
	Originally invented to handle ping replies in a jabber 
	server/console-kit hybrid. This could be useful in 
        realtime servers etc as well and perhaps belongs in 
        something like the async package.
