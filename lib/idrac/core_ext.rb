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