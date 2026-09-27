#!/usr/bin/env ruby
# Local-only enhancement of an independently runnable HomeRouter subscription.
require 'yaml'
require_relative 'local_entry_dns'

module EntryGroups
  AUTO = '♻️ 自动容灾'
  POOL = '🧩 入口候选'
  REGIONS = {
    '香港' => /香港|深港|\bHK\b|Hong\s*Kong|🇭🇰/i,
    '台湾' => /台湾|台灣|新北|彰化|\bTW\b|Taiwan|🇹🇼/i,
    '新加坡' => /新加坡|狮城|\bSG\b|Singapore|🇸🇬/i,
    '日本' => /日本|东京|大阪|\bJP\b|Japan|🇯🇵/i,
    '美国' => /美国|美國|洛杉矶|硅谷|\bUSA?\b|United\s*States|🇺🇸/i,
    '韩国' => /韩国|韓國|首尔|\bKR\b|Korea|🇰🇷/i,
    '加拿大' => /加拿大|\bCA\b|Canada|🇨🇦/i,
    '英国' => /英国|英國|伦敦|\bUK\b|Britain|United\s*Kingdom|🇬🇧/i,
    '德国' => /德国|德國|\bDE\b|Germany|🇩🇪/i,
    '法国' => /法国|法國|\bFR\b|France|🇫🇷/i,
    '荷兰' => /荷兰|荷蘭|\bNL\b|Netherlands|🇳🇱/i,
    '土耳其' => /土耳其|Turkey|Türkiye|🇹🇷/i,
    '澳大利亚' => /澳大利亚|澳洲|Australia|🇦🇺/i,
    '印度' => /印度|India|🇮🇳/i
  }.freeze

  def self.region(node)
    REGIONS.find { |_, pattern| node['name'].match?(pattern) }&.first || '未标注地区'
  end

  def self.transform(config, addresses, region_order = REGIONS.keys)
    groups = config.fetch('proxy-groups')
    auto = groups.find { |g| g['name'] == AUTO }
    pool = groups.find { |g| g['name'] == POOL }
    raise 'HomeRouter markers missing' unless auto && pool
    raise 'IPv6 profile not supported' if config['ipv6'] == true
    names = pool.fetch('proxies').reject { |n| n == 'REJECT' }
    nodes = config.fetch('proxies').select { |p| names.include?(p['name']) }
    buckets = {}; unconfirmed = 0
    nodes.each do |node|
      host = LocalEntryDNS.hostname(node['server'])
      ips = Array(addresses[host]).select { |ip| LocalEntryDNS.public_ipv4?(ip) }.uniq.sort
      unconfirmed += 1 if ips.empty?
      # Only identical, corroborated complete address sets may merge hostnames.
      # A failed/conflicting lookup retains that hostname; it never joins an unknown pool.
      key = [region(node), ips.empty? ? ['host', host] : ['ips'] + ips]
      buckets[key] ||= { region: key[0], ips: ips, hosts: [], nodes: [] }
      buckets[key][:hosts] << host
      buckets[key][:nodes] << node['name']
    end
    sorted = buckets.values.sort_by do |b|
      [region_order.index(b[:region]) || region_order.length, b[:region], b[:hosts].uniq.sort]
    end
    common = { 'type' => 'url-test', 'url' => pool.fetch('url'), 'interval' => 60,
               'timeout' => 3000, 'tolerance' => 150, 'lazy' => false,
               'interrupt-existing-connections' => false }
    generated = sorted.map do |b|
      label = b[:ips].empty? ? b[:hosts].first + '（未确认）' : b[:ips].join('+')
      common.merge('name' => '🧩 ' + b[:region] + '入口 ' + label, 'proxies' => b[:nodes])
    end
    generated << common.merge('name' => '🧩 无可用候选', 'proxies' => ['REJECT']) if generated.empty?
    keep = groups.reject { |g| g['name'] == POOL }
    existing = keep.map { |g| g['name'] } + config['proxies'].map { |p| p['name'] }
    raise 'Generated group name collision' unless (existing & generated.map { |g| g['name'] }).empty?
    auto.replace('name' => AUTO, 'type' => 'fallback', 'url' => pool.fetch('url'),
                 'proxies' => generated.map { |g| g['name'] }, 'interval' => 60,
                 'timeout' => 3000, 'lazy' => false, 'interrupt-existing-connections' => false)
    config['proxy-groups'] = keep + generated
    { 'groups' => generated.length, 'candidate_nodes' => nodes.length,
      'unconfirmed_nodes' => unconfirmed, 'group_names' => generated.map { |g| g['name'] } }
  end

  def self.unshare(value)
    case value
    when Hash then value.to_h { |k, v| [k.dup, unshare(v)] }
    when Array then value.map { |v| unshare(v) }
    when String then value.dup
    else value
    end
  end

  def self.publish(path, config)
    temp = path + '.entry-groups.' + Process.pid.to_s + '.tmp'
    created = false
    begin
      File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0600) { |f| f.write(unshare(config).to_yaml) }
      created = true
      raise 'Candidate validation failed; original YAML retained' unless yield(temp)
      File.chmod(File.stat(path).mode & 0777, temp)
      File.rename(temp, path)
    ensure
      File.unlink(temp) if created && File.file?(temp)
    end
  end

  def self.validate(path, settings)
    home = settings.fetch('core_home', '/etc/openclash')
    core = settings.fetch('core', '/etc/openclash/clash')
    log = settings.fetch('validation_log', '/tmp/openclash-entry-validation.log')
    safe = [ENV['SAFE_PATHS'], '/usr/share/openclash', '/etc/ssl', File.dirname(path)].compact.join(':')
    File.open(log, 'w', 0600) do |output|
      system({ 'SAFE_PATHS' => safe }, core, '-t', '-d', home, '-f', path, out: output, err: [:child, :out])
    end
  end

  def self.run(path, settings_path)
    config = YAML.load_file(path, aliases: true)
    pool = config.fetch('proxy-groups', []).find { |g| g['name'] == POOL }
    return unless pool
    settings = File.file?(settings_path) ? YAML.safe_load(File.read(settings_path)) : {}
    settings ||= {}
    hosts = config.fetch('proxies').select { |p| pool['proxies'].include?(p['name']) }
                  .map { |p| LocalEntryDNS.hostname(p['server']) }.uniq
    evidence = LocalEntryDNS.collect(hosts, settings)
    confirmed = LocalEntryDNS.confirmed(evidence)
    result = transform(config, confirmed, settings.fetch('region_order', REGIONS.keys))
    if settings.fetch('harden_node_dns', true)
      raise 'Trusted DNS unavailable for some candidates; original YAML retained' if evidence.any? { |_, e| e['doh'].all?(&:empty?) }
      dns = config['dns'] ||= {}
      raise 'Existing node DNS policy needs review' unless (dns['proxy-server-nameserver-policy'] || {}).empty?
      dns['proxy-server-nameserver'] = settings.fetch('doh', LocalEntryDNS::DEFAULT_DOH)
    end
    result['doh_agreed_hosts'] = confirmed.count { |_, ips| !ips.empty? }
    result['local_differs_hosts'] = confirmed.count { |host, ips| !ips.empty? && !evidence[host]['local'].empty? && ips != evidence[host]['local'] }
    result['local_unavailable_hosts'] = evidence.count { |_, e| e['local'].empty? }
    publish(path, config) { |candidate| validate(candidate, settings) }
    # Evidence is diagnostic only. Failure to write it must not break applied configuration.
    if settings['report_path']
      begin
        File.open(settings['report_path'], 'w', 0600) { |f| f.write({ 'summary' => result, 'dns_evidence' => evidence }.to_yaml) }
      rescue StandardError
        warn 'HomeRouter: could not save DNS evidence'
      end
    end
    puts "HomeRouter: #{result['groups']} regional ingress groups; #{result['unconfirmed_nodes']} unconfirmed nodes; ISP differences=#{result['local_differs_hosts']}"
  end
end

if $PROGRAM_NAME == __FILE__
  EntryGroups.run(ARGV.fetch(0), ARGV[1] || '/etc/openclash/custom/entry-groups.yaml')
end
