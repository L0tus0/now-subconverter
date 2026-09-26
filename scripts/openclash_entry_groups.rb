#!/usr/bin/env ruby
# Generate URLTest groups for shared IPv4 ingress, then a fallback over groups.
require 'yaml'

module EntryGroups
  AUTO = '♻️ 自动容灾'
  POOL = '🧩 入口候选'
  PREFIX = '🧩 入口 '
  UNKNOWN = '🧩 入口未确认'

  def self.ipv4?(s)
    parts = s.to_s.split('.')
    parts.length == 4 && parts.all? { |p| p.match?(/\A\d{1,3}\z/) && p.to_i <= 255 }
  end

  def self.usable_ip?(s)
    return false unless ipv4?(s)
    a, b = s.split('.').map(&:to_i)
    !(a == 0 || a == 10 || a == 127 || a >= 224 ||
      (a == 169 && b == 254) || (a == 172 && (16..31).include?(b)) ||
      (a == 192 && b == 168) || (a == 198 && [18, 19].include?(b)))
  end

  def self.resolve(host, server, gid)
    return usable_ip?(host) ? [host] : [] if ipv4?(host)
    return [] unless host.match?(/\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z/)
    # OpenClash bypasses DNS interception for its core GID. Never group FakeIPs.
    output = IO.popen('-') do |io|
      if io
        watchdog = Thread.new { sleep 6; Process.kill('KILL', io.pid) rescue nil }
        begin
          io.read
        ensure
          watchdog.kill
          watchdog.join
        end
      else
        Process::GID.change_privilege(gid)
        STDERR.reopen('/dev/null')
        exec('nslookup', '-type=A', host, server)
      end
    end
    output.split(/Name:/, 2).fetch(1, '').scan(/^Address(?: \d+)?:\s*(\d+\.\d+\.\d+\.\d+)/)
          .flatten.select { |ip| usable_ip?(ip) }.uniq.sort
  end

  def self.transform(config, addresses, priority = [])
    groups = config.fetch('proxy-groups')
    auto = groups.find { |g| g['name'] == AUTO }
    pool = groups.find { |g| g['name'] == POOL }
    raise 'HomeRouter entry-group markers missing' unless auto && pool
    raise 'IPv6 ingress is not supported by this profile' if config['ipv6'] == true
    names = pool.fetch('proxies').reject { |n| n == 'REJECT' }
    nodes = config.fetch('proxies').select { |p| names.include?(p['name']) }
    # Merge intersecting address sets transitively: two multi-address hostnames
    # sharing even one ingress must not be presented as independent backups.
    buckets = []
    unknown = []
    nodes.each do |node|
      ips = Array(addresses[node['server']]).select { |ip| usable_ip?(ip) }.uniq.sort
      if ips.empty?
        unknown << node['name']
        next
      end
      matches = buckets.select { |b| !(b[:ips] & ips).empty? }
      merged = { ips: (ips + matches.flat_map { |b| b[:ips] }).uniq.sort,
                 nodes: [node['name']] + matches.flat_map { |b| b[:nodes] } }
      buckets -= matches
      buckets << merged
    end
    buckets.sort_by! do |b|
      rank = priority.each_index.find { |i| b[:ips].include?(priority[i]) } || priority.length
      [rank, b[:ips].first.split('.').map(&:to_i)]
    end
    common = { 'type' => 'url-test', 'url' => pool.fetch('url'),
               'interval' => 60, 'timeout' => 3000, 'tolerance' => 150,
               'lazy' => false, 'interrupt-existing-connections' => false }
    generated = buckets.map do |b|
      common.merge('name' => PREFIX + b[:ips].join('+'),
                   'proxies' => names.select { |n| b[:nodes].include?(n) })
    end
    unless unknown.empty?
      generated << common.merge('name' => UNKNOWN, 'proxies' => unknown)
    end
    generated << common.merge('name' => UNKNOWN, 'proxies' => ['REJECT']) if generated.empty?
    keep = groups.reject { |g| g['name'] == POOL || g['name'].start_with?(PREFIX) || g['name'] == UNKNOWN }
    collision = generated.map { |g| g['name'] } & keep.map { |g| g['name'] }
    raise 'Group name collision' unless collision.empty?
    auto.replace('name' => AUTO, 'type' => 'fallback', 'proxies' => generated.map { |g| g['name'] },
                 'url' => pool.fetch('url'), 'interval' => 60, 'timeout' => 3000,
                 'lazy' => false, 'interrupt-existing-connections' => false)
    config['proxy-groups'] = keep + generated
    { 'known_groups' => buckets.length, 'unknown_nodes' => unknown.length,
      'candidate_nodes' => nodes.length, 'group_names' => generated.map { |g| g['name'] } }
  end

  def self.run(path, settings_path)
    config = YAML.load_file(path, aliases: true)
    return unless config.fetch('proxy-groups', []).any? { |g| g['name'] == POOL }
    settings = File.file?(settings_path) ? YAML.safe_load(File.read(settings_path)) : {}
    settings ||= {}
    server = settings.fetch('dns_server', '223.5.5.5')
    raise 'dns_server must be an IPv4 literal' unless ipv4?(server)
    pool = config['proxy-groups'].find { |g| g['name'] == POOL }
    hosts = config.fetch('proxies').select { |p| pool['proxies'].include?(p['name']) }
                  .map { |p| p['server'] }.uniq
    queue = Queue.new
    hosts.each { |h| queue << h }
    addresses = {}; lock = Mutex.new
    8.times.map do
      Thread.new do
        loop do
          host = (queue.pop(true) rescue nil)
          break unless host
          ips = resolve(host, server, settings.fetch('core_gid', 65534))
          lock.synchronize { addresses[host] = ips }
        end
      end
    end.each(&:value)
    result = transform(config, addresses, settings.fetch('priority', []))
    temp = path + '.entry-groups.tmp'
    begin
      File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0600) { |f| f.write(config.to_yaml) }
      File.chmod(File.stat(path).mode & 0777, temp)
      File.rename(temp, path)
    ensure
      File.unlink(temp) if File.file?(temp)
    end
    puts "HomeRouter: #{result['known_groups']} ingress groups, #{result['unknown_nodes']} unresolved candidates"
  end
end

if $PROGRAM_NAME == __FILE__
  EntryGroups.run(ARGV.fetch(0), ARGV[1] || '/etc/openclash/custom/entry-groups.yaml')
end
