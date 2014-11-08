#!/usr/bin/env ruby

def parse_ltsv(line)
  # line.split("\t").map {|a| a.split(":", 2) }.to_h
  Hash[*(line.split("\t").map {|a| a.split(":", 2) }.flatten)]
end

def stat(lines)
  stats = {}
  lines.each do |line|
    ltsv = parse_ltsv(line)
    reqtime = ltsv["reqtime"].to_f
    uri = ltsv["uri"]
    if uri =~ /slots/
      uri.gsub!(/\/slots\/[^\/]+\/ads\/[^\/]+\/(.*)/, '/slots/:slot/ads/:id/\1')
      uri.gsub!(/\/slots\/[^\/]+\/ads\/[^\/]+/, '/slots/:slot/ads/:id')
      uri.gsub!(/\/slots\/[^\/]+\/ads/, '/slots/:slot/ads')
      uri.gsub!(/\/slots\/[^\/]+\/ad/, '/slots/:slot/ad')
    end
    method = ltsv["method"]
    stat = stats["#{method} #{uri}"] ||= { :count => 0, :sum => 0, :min => 0, :max => 0}
    stat[:sum] += reqtime
    stat[:max] = [stat[:max], reqtime].max
    stat[:min] = [stat[:min], reqtime].min
    stat[:count] += 1
  end

  stats.each do |uri, stat|
    stat[:mean] = stat[:sum] / stat[:count].to_f
    out = { "uri" => uri }.merge(stat)
    puts out.map {|key, v| "#{key}:#{v}" }.join("\t")
  end
end

lines = STDIN.readlines
request_lines = lines.grep(/\turi:.*reqtime:/)
stat(request_lines)
