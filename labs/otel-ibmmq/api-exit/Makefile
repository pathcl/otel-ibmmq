# Builds otel_exit.so — IBM MQ ApiExitLocal for W3C traceparent propagation.
#
# Requires IBM MQ client libraries and headers installed on the build host.
# Default MQ install path: /opt/mqm
#
# Usage:
#   make            # build
#   make install    # copy to /var/mqm/exits64/ (requires root or mqm group)
#   make clean

MQ_HOME   ?= /opt/mqm
CC         = gcc
CFLAGS     = -fPIC -shared -O2 -Wall \
             -I$(MQ_HOME)/inc \
             -Wl,-rpath,$(MQ_HOME)/lib64
LDFLAGS    = -L$(MQ_HOME)/lib64 -lmqm_r
TARGET     = otel_exit.so
INSTALL_DIR = /var/mqm/exits64

$(TARGET): otel_exit.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

install: $(TARGET)
	cp $(TARGET) $(INSTALL_DIR)/otel_exit.so

clean:
	rm -f $(TARGET)
