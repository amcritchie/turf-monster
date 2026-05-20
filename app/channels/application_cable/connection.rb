module ApplicationCable
  # Bare connection — the contest chat streams are public-read and Turbo signs
  # its own stream names, so no per-user identification is needed here.
  class Connection < ActionCable::Connection::Base
  end
end
