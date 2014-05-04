Order = GLOBAL.db.Order
Wallet = GLOBAL.db.Wallet
MarketStats = GLOBAL.db.MarketStats
MarketHelper = require "../lib/market_helper"
JsonRenderer = require "../lib/json_renderer"
ClientSocket = require "../lib/client_socket"
_ = require "underscore"
usersSocket = new ClientSocket
  namespace: "users"
  redis: GLOBAL.appConfig().redis
math = require("mathjs")
  number: "bignumber"
  decimals: 8

module.exports = (app)->

  app.post "/orders", (req, res)->
    return JsonRenderer.error "You need to be logged in to place an order.", res  if not req.user
    return JsonRenderer.error "Sorry, but you can not trade. Did you verify your account?", res  if not req.user.canTrade()
    data = req.body
    data.user_id = req.user.id
    data.status = "open"
    data.amount = parseFloat data.amount
    data.amount = MarketHelper.toBigint data.amount  if _.isNumber(data.amount) and not _.isNaN(data.amount) and _.isFinite(data.amount)
    data.unit_price = parseFloat data.unit_price
    data.unit_price = MarketHelper.toBigint data.unit_price  if _.isNumber(data.unit_price) and not _.isNaN(data.unit_price) and _.isFinite(data.unit_price)
    orderCurrency = data["#{data.action}_currency"]
    MarketStats.findEnabledMarket orderCurrency, "BTC", (err, market)->
      return JsonRenderer.error "Can't submit the order, the #{orderCurrency} market is closed at the moment.", res  if not market
      holdBalance = math.multiply(data.amount, MarketHelper.fromBigint(data.unit_price))  if data.type is "limit" and data.action is "buy"
      holdBalance = data.amount  if data.type is "limit" and data.action is "sell"
      Wallet.findOrCreateUserWalletByCurrency req.user.id, data.buy_currency, (err, buyWallet)->
        return JsonRenderer.error "Wallet #{data.buy_currency} does not exist.", res  if err or not buyWallet
        Wallet.findOrCreateUserWalletByCurrency req.user.id, data.sell_currency, (err, wallet)->
          return JsonRenderer.error "Wallet #{data.sell_currency} does not exist.", res  if err or not wallet
          GLOBAL.db.sequelize.transaction (transaction)->
            wallet.holdBalance holdBalance, transaction, (err, wallet)->
              if err or not wallet
                console.error err
                return transaction.rollback().success ()->
                  JsonRenderer.error "Not enough #{data.sell_currency} to open an order.", res
              Order.create(data, {transaction: transaction}).complete (err, newOrder)->
                if err
                  console.error err
                  return transaction.rollback().success ()->
                    JsonRenderer.error err, res
                transaction.commit().success ()->
                  newOrder.publish (err, order)->
                    console.error "Could not publish newly created order - #{err}"  if err
                    return res.json JsonRenderer.order newOrder  if err
                    res.json JsonRenderer.order order
                  usersSocket.send
                    type: "wallet-balance-changed"
                    user_id: wallet.user_id
                    eventData: JsonRenderer.wallet wallet
                transaction.done (err)->
                  JsonRenderer.error "Could not open an order. Please try again later.", res  if err

  app.get "/orders", (req, res)->
    req.query.user_id = req.user.id  if req.query.user_id?
    Order.findByOptions req.query, (err, orders)->
      return JsonRenderer.error "Sorry, could not get open orders...", res  if err
      res.json JsonRenderer.orders orders

  app.del "/orders/:id", (req, res)->
    return JsonRenderer.error "You need to be logged in to delete an order.", res  if not req.user
    Order.findByUserAndId req.params.id, req.user.id, (err, order)->
      return JsonRenderer.error "Sorry, could not delete orders...", res  if err or not order
      order.cancel (err)->
        console.error "Could not cancel order - #{err}"  if err
        return res.json JsonRenderer.order order  if err
        res.json {}
