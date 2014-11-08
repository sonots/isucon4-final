#!/usr/bin/env ruby

def parse_ltsv(line)
  # line.split("\t").map {|a| a.split(":", 2) }.to_h
  Hash[*(line.split("\t").map {|a| a.split(":", 2) }.flatten)]
end

def stat(lines)
  stats = {}
  lines.each do |line|
    ltsv = parse_ltsv(line)
    time = ltsv["elapsed"].to_f
    template = ltsv["template"]
    stat = stats[template] ||= { :count => 0, :sum => 0, :min => 0, :max => 0}
    stat[:sum] += time
    stat[:max] = [stat[:max], time].max
    stat[:min] = [stat[:min], time].min
    stat[:count] += 1
  end

  stats.each do |template, stat|
    stat[:mean] = stat[:sum] / stat[:count].to_f
    out = { "template" => template }.merge(stat)
    puts out.map {|key, v| "#{key}:#{v}" }.join("\t")
  end
end

lines = STDIN.readlines
template_lines = lines.grep(/\ttemplate:.*elapsed/)
stat(template_lines)
