$LOADED_FEATURES << 'resolv-replace.rb'

require 'dotenv/load'
require 'vk_cozy'

# Инициализация бота
bot = VkCozy::Bot.new(ENV['GROUP_TOKEN'])

# Используем Filter::Text напрямую
bot.on.message_handler(Filter::Text.new('hello'), -> (event) {
  event.answer('Hello World!')
})

puts "Бот запущен. Напишите 'hello' в сообщения группы."
bot.run_polling
