//+------------------------------------------------------------------+
//|                                            FxSigExec.mq4 |
//            Copyright 2019, Carlos Eduardo Lopez |
//                                        c.lopez@kmels.net |
//+------------------------------------------------------------------+
#property copyright "Copyright 2019, Carlos Eduardo Lopez"
#property link      "c.lopez@kmels.net"
#property version   "1.00"
#property strict

#include <Zmq/Zmq.mqh>
#include "fxsigs.mqh"

Context context;

string host = "127.0.0.1";

string handle_req(string cmd, string payload) {
   string reply = NULL;
   bool jsonPayload = true;
   cmd = StringTrimLeft(StringTrimRight(cmd));
   
   JSONObject *o = NULL;

   if (jsonPayload) {
      JSONParser *p = new JSONParser();
      JSONValue *v = p.parse(payload);
      
      if (v == NULL) {
         Print("JSON Parser error : ");
         Print((string)p.getErrorCode()+p.getErrorMessage());
         Print(payload);
         return reply;
      } 
      
      if (false == v.isObject()) {
         Print("JSON value is not the expected object");
         return reply;
      }
      
      delete p;
      o = v;
   } else {
      delete o;
   }
   
   if (StringCompare("Trade",cmd) == 0) {
      Print("Parsing trade risk ...", o);
      double riskpct = o.getDouble("balance_risk_pct");
      Print("Parsing trade risk ... DONE");

      Print("Parsing fx signal to trade ...");
      FxSignal *it = makeFxSignal(o, payload);
      Print("Parsing fx signal to trade ... DONE");

      Print("Trading ", riskpct);
      int ticket = Execute_Trade(it, riskpct);
      reply = IntegerToString(ticket);
   }
   else if (StringCompare("Score", cmd) == 0) {
      int dateOffset = (int)MathRound((TimeCurrent() - TimeLocal())/3600.0);
      dateOffset *= 3600;

      FxSignal *it = makeFxSignal(o, payload);

      it.date += dateOffset;
      it.inserted_at += dateOffset;
      ScoreResult* c = scoreFxSignal(it);

      Print("Score result: ");
      Print(c.pretty());
      Print("Score reply: ");
      Print(c.json());
      c.invalidated_on -= dateOffset;
      c.last_available -= dateOffset;
      c.last_checked -= dateOffset;
      c.opened_on -= dateOffset;
      c.published_on -= dateOffset;
      Print(c.json());
      reply = c.json();
   } 
   else if (StringCompare("Ping", cmd) == 0) {
      reply = "Pong!";
      reply += " " + IntegerToString(o.getInt("chat_id"));
      reply += " " + IntegerToString(o.getInt("message_id"));
   } 
   else if (StringCompare("Risk", cmd) == 0) {
      double percentage = o.getDouble("risk_percentage");
      Print(DoubleToStr(percentage));
      double balance = o.getDouble("risk_balance");
      Print(DoubleToStr(balance));
      string currency = o.getString("risk_currency");
      Print(currency);
      FxSignal *it = makeFxSignal(o, payload);
      
      double lot_size = possize(it, currency, balance, percentage);
      reply = DoubleToString(lot_size, 2);
      reply += " " + IntegerToString(o.getInt("chat_id"));
      reply += " " + IntegerToString(o.getInt("message_id"));
   }
   
   if (o)
      delete o;
   return reply;
}

void SCORE() {
   
}

int OnInit()
  {
   Print("Connecting command requests ...");
   
   Print("Connecting to signals ...");
   Socket subscriber(context,ZMQ_SUB);
   subscriber.connect("tcp://" + host + ":5555");
   subscriber.subscribe("*");
   Print("Subscribing to " + IntegerToString(AccountNumber()));
   subscriber.subscribe("" + IntegerToString(AccountNumber()));
   
   Print("Connecting command responses...");
   PollItem items[1];
   subscriber.fillPollItem(items[0],ZMQ_POLLIN);
   
   Socket sender(context, ZMQ_PUSH);
   sender.connect("tcp://" + host + ":5557"); 
   
   while(!IsStopped())
     {
      ZmqMsg message;
      //--- MQL Note: To handle Script exit properly, we set a timeout of 500 ms instead of infinite wait
      Socket::poll(items,500);

      if(items[0].hasInput())
        {
         subscriber.recv(message);
         string request = message.getData(); 
         
         Print("Suscriber input: " + request);
         
         string worker;
         string command;
         string payload;
         
         int worker_pos = StringFind(request, " ",0);
         int command_pos = StringFind(request, " ",worker_pos + 1);
         
         worker = StringSubstr(request, 0, worker_pos);
         Print("Worker: " + worker);
         command = StringSubstr(request, worker_pos + 1, command_pos - worker_pos);
         Print("Command: "+ command);
         payload = StringSubstr(request, command_pos + 1, StringLen(request) - command_pos - 1);
         Print("Payload: "+ payload);
         
         string response = handle_req(command, payload);
         Print(command + ". Replying: " + response);
         if (response != NULL)
            sender.send(AccountInfoInteger(ACCOUNT_NUMBER)+" OK " + command + " " + response);
        }
     } 

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
