require 'httparty'

module VKApi
  BASE = 'https://api.vk.com/method'
  VER  = '5.131'

  def self.send(peer_id, text, keyboard = nil)
    params = { access_token: ENV['VK_ACCESS_TOKEN'], group_id: ENV['VK_GROUP_ID'], v: VER, peer_id: peer_id, message: text }
    params[:keyboard] = keyboard.to_json if keyboard
    HTTParty.post("#{BASE}/messages.send", query: params)
  end
end