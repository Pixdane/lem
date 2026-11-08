"use strict";

import {
  JSONRPCServerAndClient,
  JSONRPCServer,
  JSONRPCClient,
} from "json-rpc-2.0";

export class JSONRPC {
  constructor(url, { onConnected, onClosed }) {
    this.url = url;
    this.onConnected = onConnected;
    this.onClosed = onClosed;

    this.messageQueue = [];
    this.serverAndClient = null;
    this.connect();
    this.connectionEstablished = false;

    this.timerId = null;
    this.closed = false;
  }

  close() {
    this.closed = true;
    if (this.timerId) {
      clearTimeout(this.timerId);
      this.timerId = null;
    }
    this.webSocket.close();
  }

  on(method, handler) {
    this.serverAndClient.addMethod(method, handler);
  }

  async requestInternal(method, arg, callback) {
    const result = await this.serverAndClient.request(method, arg);
    if (callback) {
      callback(result);
    }
  }

  requestMessageQueue() {
    this.messageQueue.forEach((value) => {
      const [method, arg, callback] = value;
      this.requestInternal(method, arg, callback);
    });
    this.messageQueue = [];
  }

  request(method, arg, callback) {
    if (this.webSocket.readyState === WebSocket.OPEN) {
      this.requestInternal(method, arg, callback);
    } else {
      this.messageQueue.push([method, arg, callback]);
    }
  }

  notify(method, arg) {
    //console.log('notify', this.webSocket.readyState);
    switch (this.webSocket.readyState) {
      case WebSocket.OPEN:
        this.serverAndClient.notify(method, arg);
        break;
      case WebSocket.CLOSED:
        break;
    }
  }

  connect(webSocket) {
    if (this.closed) return;

    console.log('connect', this.url);
    this.webSocket = new WebSocket(this.url);

    if (!this.serverAndClient) {
      this.serverAndClient = new JSONRPCServerAndClient(
        new JSONRPCServer(),
        new JSONRPCClient((request) => {
          try {
            //console.log(request);
            this.webSocket.send(JSON.stringify(request));
            return Promise.resolve();
          } catch (error) {
            return Promise.reject(error);
          }
        })
      );
    }

    this.webSocket.onmessage = (event) => {
      this.serverAndClient.receiveAndSend(JSON.parse(event.data.toString()));
    };

    this.webSocket.onopen = () => {
      console.log("WebSocket connection established");
      this.connectionEstablished = true;
      if (typeof this.onConnected === 'function') {
        this.onConnected();
      }
      this.requestMessageQueue();
    };

    this.webSocket.onclose = (event) => {
      console.error("WebScoket closed", event);
      this.serverAndClient.rejectAllPendingRequests(
        `Connection is closed (${event.reason}).`
      );

      const wasEstablished = this.connectionEstablished;
      this.connectionEstablished = false;
      if (this.closed) {
        return;
      }

      // Schedule the reconnect before invoking the application callback so a
      // missing or throwing onClosed cannot prevent recovery.
      this.timerId = setTimeout(() => {
        this.timerId = null;
        this.connect();
      }, 3000);

      if (wasEstablished && typeof this.onClosed === 'function') {
        this.onClosed();
      }
    };

    this.webSocket.onerror = (error) => {
      console.error("WebSocket error:", error);
      this.webSocket.close();
    };
  }
}
