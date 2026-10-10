
# Makefile for managing local Nginx instance

# Current directory
PWD := $(shell pwd)

.PHONY: start stop reload clean

logs:
	mkdir -p logs

# The TLS key is generated locally, never committed.
key.pem cert.pem:
	sh gen_certs.sh

start: logs key.pem
	nginx -p $(PWD) -c nginx.conf

stop:
	nginx -p $(PWD) -s stop

reload:
	nginx -p $(PWD) -s reload

check:
	nginx -p $(PWD) -c nginx.conf -t

clean:
	rm -rf logs
