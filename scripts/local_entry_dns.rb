# Minimal DNS-over-HTTPS wire client for OpenWrt Ruby without json/socket gems.
require 'yaml'

module LocalEntryDNS
  DEFAULT_DOH = ['https://223.5.5.5/dns-query', 'https://1.12.12.12/dns-query'].freeze

  def self.public_ipv4?(s)
    p = s.to_s.split('.')
    return false unless p.length == 4 && p.all? { |x| x.match?(/\A\d{1,3}\z/) && x.to_i <= 255 }
    a, b = p.map(&:to_i)
    !(a == 0 || a == 10 || a == 127 || a >= 224 ||
      (a == 100 && (64..127).include?(b)) || (a == 169 && b == 254) ||
      (a == 172 && (16..31).include?(b)) || (a == 192 && b == 168) ||
      (a == 198 && [18, 19].include?(b)))
  end

  def self.hostname(s)
    s.to_s.downcase.sub(/\.$/, '')
  end

  def self.question(host)
    labels = hostname(host).split('.')
    raise 'Invalid DNS hostname' unless labels.all? { |x| x.match?(/\A[a-z0-9_-]{1,63}\z/) } && host.bytesize <= 253
    [0, 256, 1, 0, 0, 0].pack('n6') + labels.map { |x| [x.bytesize].pack('C') + x }.join + "\0" + [1, 1].pack('n2')
  end

  def self.name(packet, offset)
    labels = []; seen = []; finish = nil
    loop do
      raise 'Invalid DNS compression' if seen.include?(offset) || seen.length > 128 || offset >= packet.bytesize
      seen << offset
      len = packet.getbyte(offset)
      if (len & 0xc0) == 0xc0
        raise 'Short DNS pointer' if offset + 1 >= packet.bytesize
        finish ||= offset + 2
        offset = ((len & 0x3f) << 8) | packet.getbyte(offset + 1)
      elsif len == 0
        return [labels.join('.').downcase, finish || offset + 1]
      else
        raise 'Invalid DNS label' if len > 63 || offset + len >= packet.bytesize
        labels << packet.byteslice(offset + 1, len)
        offset += len + 1
      end
    end
  end

  def self.answers(packet, host)
    raise 'Short DNS response' if packet.bytesize < 12
    id, flags, qd, an, = packet.unpack('n6')
    raise 'Invalid DNS response' unless id == 0 && flags & 0x8000 != 0 && flags & 0x020f == 0 && qd == 1
    qname, offset = name(packet, 12)
    raise 'Mismatched DNS question' unless qname == hostname(host) && packet.byteslice(offset, 4) == [1, 1].pack('n2')
    offset += 4
    aliases = []; addresses = []
    an.times do
      owner, offset = name(packet, offset)
      raise 'Short DNS record' if offset + 10 > packet.bytesize
      type, klass, _ttl, length = packet.byteslice(offset, 10).unpack('nnNn')
      offset += 10
      raise 'Short DNS data' if offset + length > packet.bytesize
      if klass == 1 && type == 1 && length == 4
        addresses << [owner, packet.byteslice(offset, 4).unpack('C4').join('.')]
      elsif klass == 1 && type == 5
        aliases << [owner, name(packet, offset).first]
      end
      offset += length
    end
    allowed = [qname]
    aliases.length.times { aliases.each { |from, to| allowed << to if allowed.include?(from) && !allowed.include?(to) } }
    addresses.select { |owner, ip| allowed.include?(owner) && public_ipv4?(ip) }.map(&:last).uniq.sort
  end

  def self.command(args, gid, seconds)
    IO.popen('-') do |io|
      if io
        watchdog = Thread.new { sleep seconds; Process.kill('KILL', io.pid) rescue nil }
        begin
          io.read
        ensure
          watchdog.kill; watchdog.join
        end
      else
        Process::GID.change_privilege(gid)
        STDERR.reopen('/dev/null')
        exec(*args)
      end
    end
  end

  def self.doh(host, endpoint, gid)
    # IP-literal HTTPS URLs avoid relying on ISP DNS to bootstrap the DoH host.
    raise 'Use a reviewed IPv4 HTTPS DoH endpoint' unless endpoint.match?(%r{\Ahttps://\d+\.\d+\.\d+\.\d+/dns-query\z})
    query = [question(host)].pack('m0').tr('+/', '-_').delete('=')
    packet = command(['curl', '-fsS', '--noproxy', '*', '--connect-timeout', '2', '--max-time', '3',
                      '--max-filesize', '65536', '-H', 'Accept: application/dns-message', endpoint + '?dns=' + query], gid, 4)
    answers(packet, host)
  rescue StandardError
    []
  end

  def self.local(host, server, gid)
    return [] unless server.match?(/\A\d+\.\d+\.\d+\.\d+\z/)
    output = command(['nslookup', '-type=A', host, server], gid, 3)
    output.split(/Name:/, 2).fetch(1, '').scan(/^Address(?: \d+)?:\s*(\d+\.\d+\.\d+\.\d+)/)
          .flatten.select { |ip| public_ipv4?(ip) }.uniq.sort
  rescue StandardError
    []
  end

  def self.collect(hosts, settings, stats: {})
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    retry_limit = Integer(settings.fetch('dns_retries', 2))
    raise 'dns_retries must be between 0 and 3' unless (0..3).include?(retry_limit)
    endpoints = settings.fetch('doh', DEFAULT_DOH)
    raise 'Two distinct reviewed DoH endpoints are required' unless endpoints.length == 2 && endpoints.uniq.length == 2 &&
      endpoints.all? { |s| s.match?(%r{\Ahttps://\d+\.\d+\.\d+\.\d+/dns-query\z}) }
    gid = settings.fetch('core_gid', 65534)
    local_server = settings.fetch('diagnostic_dns', '223.5.5.5')
    evidence = {}; queue = Queue.new; lock = Mutex.new
    hosts.each do |host|
      evidence[host] = { 'doh' => [[], []], 'local' => [] }
      if public_ipv4?(host)
        evidence[host] = { 'doh' => [[host], [host]], 'local' => [host] }
      else
        3.times { |i| queue << [host, i] }
      end
    end
    deadline = started + settings.fetch('resolution_budget', 25)
    12.times.map do
      Thread.new do
        loop do
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          task = (queue.pop(true) rescue nil)
          break unless task
          host, index = task
          ips = index == 2 ? local(host, local_server, gid) : doh(host, endpoints[index], gid)
          lock.synchronize do
            index == 2 ? evidence[host]['local'] = ips : evidence[host]['doh'][index] = ips
          end
        end
      end
    end.each(&:value)
    # A burst may leave a resolver temporarily unanswered. Retry only missing
    # DoH answers at lower concurrency and within the same time budget.
    # Keep valid answers unchanged; disagreement must remain visible.
    stats['retry_limit'] = retry_limit
    stats['retry_rounds'] = []
    retry_limit.times do |round|
      retries = Queue.new
      evidence.each do |host, item|
        item['doh'].each_with_index { |ips, i| retries << [host, i] if ips.empty? }
      end
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if retries.empty? || remaining <= 0
      # Brief backoff limits repeated bursts without imposing a delay on success.
      sleep [0.25 * (round + 1), remaining].min
      round_stats = { 'attempts' => 0, 'recovered' => 0 }
      2.times.map do
        Thread.new do
          loop do
            break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            task = (retries.pop(true) rescue nil)
            break unless task
            host, index = task
            ips = doh(host, endpoints[index], gid)
            lock.synchronize do
              evidence[host]['doh'][index] = ips
              round_stats['attempts'] += 1
              round_stats['recovered'] += 1 unless ips.empty?
            end
          end
        end
      end.each(&:value)
      stats['retry_rounds'] << round_stats if round_stats['attempts'] > 0
    end
    stats['seconds'] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
    stats['budget_exhausted'] = Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    evidence
  end

  def self.confirmed(evidence)
    evidence.to_h do |host, result|
      sets = result.fetch('doh').map { |a| a.select { |ip| public_ipv4?(ip) }.uniq.sort }
      [host, sets.length == 2 && !sets[0].empty? && sets[0] == sets[1] ? sets[0] : []]
    end
  end
end
