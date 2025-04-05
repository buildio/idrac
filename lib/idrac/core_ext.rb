# frozen_string_literal: true

# Add ActiveSupport-like blank? method to core Ruby classes
# This allows us to use blank? without requiring Rails' ActiveSupport

class NilClass
  # nil is always blank
  def blank?
    true
  end
end

class String
  # A string is blank if it's empty or contains whitespace only
  def blank?
    strip.empty?
  end
end

class Array
  # An array is blank if it's empty
  def blank?
    empty?
  end
end

class Hash
  # A hash is blank if it's empty
  def blank?
    empty?
  end
end

class Object
  # An object is blank if it responds to empty? and is empty
  # Otherwise return false
  def blank?
    respond_to?(:empty?) ? empty? : false
  end
end

# Add ActiveSupport-like numeric extensions
class Integer
  # Byte size helpers
  def byte
    self
  end
  alias_method :bytes, :byte
  
  def kilobyte
    self * 1024
  end
  alias_method :kilobytes, :kilobyte
  
  def megabyte
    self * 1024 * 1024
  end
  alias_method :megabytes, :megabyte
  
  def gigabyte
    self * 1024 * 1024 * 1024
  end
  alias_method :gigabytes, :gigabyte
  
  def terabyte
    self * 1024 * 1024 * 1024 * 1024
  end
  alias_method :terabytes, :terabyte
  
  def petabyte
    self * 1024 * 1024 * 1024 * 1024 * 1024
  end
  alias_method :petabytes, :petabyte
  
  # Time duration helpers (for potential future use)
  def second
    self
  end
  alias_method :seconds, :second
  
  def minute
    self * 60
  end
  alias_method :minutes, :minute
  
  def hour
    self * 60 * 60
  end
  alias_method :hours, :hour
  
  def day
    self * 24 * 60 * 60
  end
  alias_method :days, :day
  
  def week
    self * 7 * 24 * 60 * 60
  end
  alias_method :weeks, :week
end 