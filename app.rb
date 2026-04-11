require 'sinatra'
require 'json'
require_relative 'bot'

set :bind, '0.0.0.0'
set :port, ENV.fetch('PORT', 4567)

post '/webhook' do
  body = JSON.parse(request.body.read)
  return ENV['VK_CONFIRMATION_CODE'] if body['type'] == 'confirmation'
  return 'ok' if body['type'] != 'message_new'

  msg = body['object']['message']
  Bot.dispatch(msg['from_id'], msg['text'].strip, msg['peer_id'])
  'ok'
end