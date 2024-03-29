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

#import "libsodium.dll"
int crypto_scalarmult(uchar &q[], const uchar &n[], const uchar &p[]); // q = nP
#import

Context context;

string host = "127.0.0.1";

string genpub,gensec;

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
   
   if (StringCompare("GetPubKey",cmd) == 0) {
      reply = "{\"pubkey\": \"" +genpub + "\"}";
   }
   else if (StringCompare("Trade",cmd) == 0) {
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

string deriveSharedKey(string myPrivKey, string theirPubKey) {
   uchar pubkey_bytes[];
   uchar privkey_bytes[];

   if (0 == Z85::decode(theirPubKey, pubkey_bytes)) {
      Print("deriveShared: Invalid pubkey");
      return NULL;
   }

   if (0 == Z85::decode(myPrivKey, privkey_bytes)) {
      Print("deriveShared: Invalid privkey");
      return NULL;
   }

   if (32 != ArraySize(pubkey_bytes)) {
       Print("deriveShared: Invalid pubkey size");
       return NULL;
   }

   if (32 != ArraySize(privkey_bytes)) {
       Print("deriveShared: Invalid privkey size");
       return NULL;
   }

   uchar sharedSecret[32];
   if (0 != crypto_scalarmult(sharedSecret,privkey_bytes,pubkey_bytes)) {
      Print("deriveShared: failed to multiply");
      return NULL;
   }

   string encodedSecret;
   if (0 == Z85::encode(encodedSecret, sharedSecret)) {
      Print("deriveShared: failed to multiply");
      return NULL;
   }
   return encodedSecret;
}

int keylen = 40;

bool Encrypt(string keystr, string text, uchar &cypher[]) {
   uchar src[],dst[],key[];
   StringToCharArray(keystr,key);
   StringToCharArray(text,src);
   ResetLastError();
   int res=CryptEncode(CRYPT_AES256,src,key,cypher);
   return res > 0;
}

string Decrypt(string keystr, uchar &dst1[]) {
Print(ArraySize(dst1));
   string s  = CharArrayToString(dst1);
   uchar dst[];
   StringToCharArray(s, dst);
   ArrayResize(dst, ArraySize(dst1));
   Print(ArraySize(dst));
   
   uchar src[],key[];
   StringToCharArray(keystr,key);
   int res=CryptDecode(CRYPT_AES256,dst,key,src);
   if (res > 0)
      return CharArrayToString(src);
   Print("Error in CryptDecode. Error code=", GetLastError());
   return NULL;
} 

string migrateZ85Key(string z85) {
   if (StringLen(z85) != 40) {
      Print("migrateZ85Key: Invalid  key");
      return NULL;
   }
   uchar key_bytes[32];
   if (0 == Z85::decode(z85, key_bytes)) {
      Print("migrateZ85Key: Invalid key");
      return NULL;
   }
   return CharArrayToString(key_bytes);
}

int OnInit()
  {
   Print("Generating key pair ... ");
   Z85::generateKeyPair(genpub,gensec);

   string theirPriv = "D:)Q[IlAW!ahhC2ac:9*A}h:p?([4%wOTJ%JR%cs";
   string theirPub = "Yne@$w-vo<fVvi]a<NY6T1ed:M$fCG*[IaLV{hID";
   
   Z85::generateKeyPair(theirPub,theirPriv);

   Print("1) Generated public key: [",genpub,"]");
   Print("1) Generated private key: [",gensec,"]");

   string myDH = deriveSharedKey(gensec, theirPub);
   string theirDH = deriveSharedKey(theirPriv, genpub);
   
   myDH = migrateZ85Key(myDH);
   theirDH = migrateZ85Key(theirDH);

   string data = "12342222225";
   
   Print("Data: ", data);
   uchar dst[];
   Encrypt(myDH, data, dst);
   string decipher = Decrypt(theirDH, dst);
   Print("Decrypted: ", decipher);
   
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

   int tick = 0;
   int keepalive_clock = 15;
   while(!IsStopped())
     {
      ZmqMsg message;
      //--- MQL Note: To handle Script exit properly, we set a timeout of 500 ms instead of infinite wait
      Socket::poll(items,500);

      if(items[0].hasInput())
        {
         subscriber.recv(message);
         string private_request = message.getData(); 
         Print("Private request: " + private_request);
         
         int cipher_pos = StringFind(private_request, " ",0);
         int keylen = 40;
         if (cipher_pos != keylen) {
            Alert("Bad request");
            continue;
         }
         
         string server_key = StringSubstr(private_request, 0, keylen);
         string encrypted_request = StringSubstr(private_request, keylen+1);
         
         Print("Server key: " + server_key);
         Print("Encrypted request: " + encrypted_request);
         
         uchar tmp[];
         StringToCharArray(encrypted_request, tmp);
         string request = Decrypt(server_key, tmp);
         
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

         string acc_number = IntegerToString(AccountNumber());
         if (response != NULL)
            sender.send(acc_number+" OK " + command + " " + response);
        } // end hasInput()

	if (MathMod(tick, keepalive_clock)==0) {
         string payload = "{";
         payload += "\"account_number\":" + IntegerToString(AccountNumber());
         payload += ", \"account_company\":\"" + AccountCompany() + "\"";
         payload += "}";
         sender.send("OK KeepAlive " + payload);
         
         tick = 0;
      	} // end keepalive clock 

	tick += 1;
	
     } // end while !IsStopped 

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
