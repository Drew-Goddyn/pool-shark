require 'drb/drb'
require 'pry'
DRb.start_service
remote_object = DRbObject.new_with_uri('druby://localhost:9999')
sleep 3
loop do
  puts `clear`
  puts remote_object.show_table
  sleep 2
end
