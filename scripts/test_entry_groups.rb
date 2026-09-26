require_relative 'openclash_entry_groups'

def check(value, message)
  raise message unless value
end

def fixture
  names = %w[a b c d e f g]
  { 'proxies' => names.map { |n| { 'name' => n, 'server' => n + '.invalid' } },
    'rules' => ['MATCH,♻️ 自动容灾'], 'dns' => { 'enable' => true },
    'proxy-groups' => [
      { 'name' => EntryGroups::AUTO, 'type' => 'fallback', 'proxies' => [EntryGroups::POOL] },
      { 'name' => EntryGroups::POOL, 'type' => 'url-test', 'url' => 'http://health.invalid',
        'proxies' => names + ['REJECT'] },
      { 'name' => 'dedicated', 'type' => 'select', 'proxies' => ['c'] }
    ] }
end

c = fixture
special = Marshal.load(Marshal.dump(c['proxy-groups'].last))
r = EntryGroups.transform(c, {
  'a.invalid' => ['1.1.1.1'], 'b.invalid' => ['2.2.2.2'],
  'c.invalid' => ['1.1.1.1', '2.2.2.2'], 'd.invalid' => ['3.3.3.3'],
  'e.invalid' => ['198.18.1.5'], 'f.invalid' => [], 'g.invalid' => ['127.0.0.1']
}, ['3.3.3.3'])
check(r['known_groups'] == 2 && r['unknown_nodes'] == 3, 'shared/multi-address merge failed')
gs = c['proxy-groups']
auto = gs.find { |g| g['name'] == EntryGroups::AUTO }
children = auto['proxies'].map { |n| gs.find { |g| g['name'] == n } }
check(children[0]['proxies'] == ['d'], 'entry priority lost')
check(children[1]['proxies'] == %w[a b c], 'overlapping IPs split into false backups')
check(children[2]['proxies'] == %w[e f g], 'unconfirmed ingress must be one last group')
check(children.all? { |g| g['type'] == 'url-test' && g['lazy'] == false }, 'child health check disabled')
check(children.flat_map { |g| g['proxies'] }.sort == %w[a b c d e f g], 'candidate coverage changed')
check(c['rules'] == ['MATCH,♻️ 自动容灾'] && c['dns'] == { 'enable' => true }, 'unrelated config changed')
check(gs.include?(special), 'dedicated group changed')
empty = fixture
empty['proxies'] = []
EntryGroups.transform(empty, {})
check(empty['proxy-groups'].last['proxies'] == ['REJECT'], 'empty pool must not become DIRECT')
ipv6 = fixture.merge('ipv6' => true)
begin
  EntryGroups.transform(ipv6, {})
  raise 'unsupported IPv6 profile accepted'
rescue RuntimeError => e
  raise unless e.message.include?('IPv6 ingress')
end
puts 'PASS: ingress grouping, overlap merge, priority, unknown/empty pools, preserved rules and dedicated routes'
