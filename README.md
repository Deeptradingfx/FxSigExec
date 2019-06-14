
## FxSigExec ZMQ ENDPOINTS
1. ** Socket type: ** PUB / SUB
1. ** Usage: **
    * FxSigExec will subscribe to messages on fxauto.expert:5555 or any other port
    * A message format is: "<Worker> <Command> <Payload>"
      * Worker: Either account number id or the * char
      * Command: See below
      * Payload: Json for the command

## FxSigExec ZMQ RESPONSES
1. ** Socket type: **  PUSH / PULL
   ** Usage: **
    * FxSigExec will push messages on fxauto.expert:5557 or any other port
    * A message format is: "<Worker> <Result> <Payload>
      * Worker: Either account number id or the * char
      * Command: "OK" or "Error"
      * Payload: Either a word or json (See each command)

### Commands ###
1. ** GetPubKey
   
1. ** Trade

1. ** Backtest

1. ** LotSize

