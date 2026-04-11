require 'mongo'
require 'redis'

# пример как взаимодействовать с backend
module Store
  @mongo = Mongo::Client.new(ENV['MONGO_URL'], database: 'vk_bot')
  @redis = Redis.new(url: ENV['REDIS_URL'])

  def self.get_state(vk_id)
    @redis.get("state:#{vk_id}") || 'menu'
  end

  def self.set_state(vk_id, state, data = {})
    @redis.set("state:#{vk_id}", state)
    @redis.set("data:#{vk_id}", data.to_json) unless data.empty?
  end

  def self.upsert_user(vk_id)
    @mongo[:users].update_one({ vk_id: vk_id }, { "$setOnInsert" => { vk_id: vk_id, stats: { total: 0, correct: 0 } } }, upsert: true)
  end
end