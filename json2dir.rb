#!/usr/bin/env ruby
# json2dir: create the directory tree a JSON document describes, in the current directory.
# Implements RFC J2D-1 (https://github.com/kitsunoff/awesome-json2dir/blob/main/spec/rfc-json2dir.md).
require "json"

class Json2dirError < StandardError; end

def fail!(message)
  raise Json2dirError, message
end

# The json gem accepts /* */ and // comments, unknown escapes like \q, and pairs a high surrogate with any following
# \u escape, so scan for those before handing the text to JSON.parse.
def prescan(text)
  s = text.b
  i = 0
  in_string = false
  while i < s.bytesize
    c = s.getbyte(i)
    if !in_string
      fail!("input is not valid JSON: comments are not allowed") if c == 0x2F # '/'
      in_string = true if c == 0x22
      i += 1
    elsif c == 0x22
      in_string = false
      i += 1
    elsif c == 0x5C # backslash
      if s.getbyte(i + 1) == 0x75 # 'u'
        hex = s[i + 2, 4]
        fail!("input is not valid JSON: bad unicode escape") unless hex =~ /\A\h{4}\z/
        cp = hex.to_i(16)
        if cp.between?(0xD800, 0xDBFF)
          low = s[i + 6, 6]
          unless low =~ /\A\\u(\h{4})\z/ && $1.to_i(16).between?(0xDC00, 0xDFFF)
            fail!("input contains an unpaired surrogate")
          end
          i += 12
        elsif cp.between?(0xDC00, 0xDFFF)
          fail!("input contains an unpaired surrogate")
        else
          i += 6
        end
      else
        fail!("input is not valid JSON: bad escape") unless '"\\/bfnrt'.include?(s[i + 1].to_s)
        i += 2
      end
    else
      i += 1
    end
  end
end

# §3: strict UTF-8 and strict JSON; a leading BOM is ignored.
def parse(bytes)
  text = bytes.dup.force_encoding(Encoding::UTF_8)
  fail!("input is not valid UTF-8") unless text.valid_encoding?
  text = text.delete_prefix("﻿")
  prescan(text)
  begin
    JSON.parse(text, max_nesting: false, allow_nan: false, create_additions: false)
  rescue JSON::ParserError => e
    fail!("input is not valid JSON: #{e.message.lines.first.to_s.strip}")
  end
end

def check_string(s, where)
  fail!("#{where}: string is not valid UTF-8") unless s.valid_encoding?
end

# §4.2.1: names are used exactly; nothing is trimmed.
def check_name(name, where)
  if name.empty? || name == "." || name == ".." || name.include?("/") || name.include?("\0")
    fail!("#{where}: invalid name #{name.inspect}")
  end
end

# §4, §6: validate the whole document before touching the file system.
def validate(value, where)
  case value
  when String
    check_string(value, where)
  when Array
    unless value.length == 2 && value.all? { |v| v.is_a?(String) }
      fail!("#{where}: an array must be [\"link\", target] or [\"script\", content]")
    end
    fail!("#{where}: unknown array kind #{value[0].inspect}") unless %w[link script].include?(value[0])
    fail!("#{where}: a link target cannot contain NUL") if value[0] == "link" && value[1].include?("\0")
    check_string(value[1], where)
  when Hash
    value.each do |name, child|
      path = where == "." ? name : "#{where}/#{name}"
      check_string(name, path)
      check_name(name, path)
      validate(child, path)
    end
  else
    fail!("#{where}: #{value.nil? ? "null" : value.class.name.downcase} values are not allowed")
  end
end

def lstat_or_nil(p)
  File.lstat(p)
rescue Errno::ENOENT
  nil
end

# §5.2, §5.3: an existing non-directory is removed (a symlink itself, never its target);
# §5.4: a directory in the way of a non-object is an error.
def clear(p, existing)
  return unless existing
  fail!("#{p}: a directory is in the way") if existing.directory?
  File.unlink(p)
end

def write_file(p, content, executable)
  # O_CREAT | O_EXCL: never writes through an entry that appeared after clear().
  File.open(p, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o666) do |f|
    f.write(content)
    f.chmod((f.stat.mode & 0o7777) | 0o111) if executable
  end
end

def apply(dir, tree)
  tree.keys.sort_by(&:b).each do |name|
    p = File.join(dir, name)
    value = tree[name]
    existing = lstat_or_nil(p)
    case value
    when String
      clear(p, existing)
      write_file(p, value, false)
    when Array
      clear(p, existing)
      if value[0] == "link"
        File.symlink(value[1], p)
      else
        write_file(p, value[1], true)
      end
    else
      unless existing&.directory?
        File.unlink(p) if existing
        Dir.mkdir(p)
      end
      apply(p, value)
    end
  end
end

def main(args)
  unless args.empty?
    $stderr.puts "usage: json2dir < document.json"
    return 2
  end
  document = parse($stdin.binmode.read)
  fail!("the root of the document must be an object") unless document.is_a?(Hash)
  validate(document, ".")
  apply(".", document)
  0
rescue Json2dirError, SystemCallError, IOError, ArgumentError, EncodingError => e
  $stderr.puts "json2dir: #{e.message}"
  1
end

exit main(ARGV)
