require_relative 'openclash_entry_groups'
def check(value, message); raise message unless value; end

def fixture
  nodes = [['香港 A','a.invalid'],['香港 B','b.invalid'],['台湾 A','c.invalid'],['日本 A','d.invalid'],['香港 unknown','e.invalid'],['香港 other','f.invalid']]
  { 'proxies' => nodes.map { |name, server| { 'name' => name, 'server' => server } },
    'rules' => ['MATCH,♻️ 自动容灾'], 'dns' => { 'enable' => true },
    'proxy-groups' => [
      { 'name' => EntryGroups::AUTO, 'type' => 'fallback', 'proxies' => [EntryGroups::POOL] },
      { 'name' => EntryGroups::POOL, 'type' => 'url-test', 'url' => 'http://health.invalid', 'proxies' => nodes.map(&:first) + ['REJECT'] },
      { 'name' => 'dedicated', 'type' => 'select', 'proxies' => ['台湾 A'] }
    ] }
end
c=fixture
r=EntryGroups.transform(c,{'a.invalid'=>['1.1.1.1'],'b.invalid'=>['2.2.2.2'],'c.invalid'=>['1.1.1.1'],'d.invalid'=>['3.3.3.3']})
auto=c['proxy-groups'].first
check(auto['proxies'][0,2]==['🧩 香港入口 1.1.1.1','🧩 香港入口 2.2.2.2'],'Region/host ordering failed')
check(auto['proxies'][2].include?('e.invalid') && auto['proxies'][3].include?('f.invalid'),'Unknown hosts incorrectly merged')
check(auto['proxies'][4]=='🧩 台湾入口 1.1.1.1','Shared ingress must split by exit region')
check(c['rules']==fixture['rules'] && c['dns']==fixture['dns'],'Unrelated config changed')
check(c['proxy-groups'][1]==fixture['proxy-groups'].last,'Dedicated group changed')
check(r['candidate_nodes']==6 && r['unconfirmed_nodes']==2,'Coverage incorrect')
check(c['proxy-groups'][2..].flat_map{|g|g['proxies']}.sort==fixture['proxies'].map{|p|p['name']}.sort,'Nodes lost/duplicated')

c=fixture
EntryGroups.transform(c,{'a.invalid'=>['1.1.1.1'],'b.invalid'=>['1.1.1.1']})
check(c['proxy-groups'][2]['proxies']==['香港 A','香港 B'],'Same region/address set did not merge')
c=fixture
EntryGroups.transform(c,{'a.invalid'=>['1.1.1.1'],'b.invalid'=>['1.1.1.1','2.2.2.2']})
check(c['proxy-groups'][2]['proxies']==['香港 A'],'Partial overlap should not merge')
c=fixture
EntryGroups.transform(c,{'a.invalid'=>['9.9.9.9'],'b.invalid'=>['2.2.2.2']})
check(c['proxy-groups'].first['proxies'].first=='🧩 香港入口 9.9.9.9','IP renumbering changed hostname order')

confirmed=LocalEntryDNS.confirmed({
 'same'=>{'doh'=>[['1.1.1.1'],['1.1.1.1']]},
 'conflict'=>{'doh'=>[['1.1.1.1'],['2.2.2.2']]},
 'failed'=>{'doh'=>[['1.1.1.1'],[]]},
 'fake'=>{'doh'=>[['198.18.1.1'],['198.18.1.1']]}})
check(confirmed['same']==['1.1.1.1'] && confirmed.values.count(&:empty?)==3,'Consensus safety failed')
q=LocalEntryDNS.question('example.com')
packet=[0,0x8180,1,1,0,0].pack('n6')+q[12..]+[0xc00c,1,1,60,4].pack('nnnNn')+[1,1,1,1].pack('C4')
check(LocalEntryDNS.answers(packet,'example.com')==['1.1.1.1'],'DNS wire parsing failed')
begin
 LocalEntryDNS.answers(packet,'wrong.example');raise 'Question mismatch accepted'
rescue RuntimeError=>e
 raise unless e.message.include?('Mismatched DNS question')
end
path='/tmp/entry-publish-test-'+Process.pid.to_s
begin
 File.write(path,'original baseline')
 begin
  EntryGroups.publish(path,fixture){false};raise 'Invalid candidate accepted'
 rescue RuntimeError=>e
  raise unless e.message.include?('original YAML retained')
 end
 check(File.read(path)=='original baseline','Failure damaged source YAML')
 EntryGroups.publish(path,fixture){|p| YAML.load_file(p);true}
 check(YAML.load_file(path)==fixture,'Valid candidate not published')
ensure
 File.unlink(path) if File.file?(path)
end
c=fixture;c['proxies']=[]
EntryGroups.transform(c,{})
check(c['proxy-groups'].last['proxies']==['REJECT'],'Empty pool became DIRECT')

# A total encrypted-DNS failure must not install a DNS policy that cannot resolve
# the candidates, even when ISP DNS returns a usable-looking address.
original_collect=LocalEntryDNS.method(:collect)
path='/tmp/entry-dns-failure-'+Process.pid.to_s
begin
 LocalEntryDNS.define_singleton_method(:collect) do |hosts,_settings|
  hosts.to_h{|h|[h,{'doh'=>[[],[]],'local'=>['1.1.1.1']}]}
 end
 baseline=fixture.to_yaml
 File.write(path,baseline)
 begin
  EntryGroups.run(path,path+'.absent-settings');raise 'Failed DoH accepted'
 rescue RuntimeError=>e
  raise unless e.message.include?('Trusted DNS unavailable')
 end
 check(File.read(path)==baseline,'DNS failure damaged baseline')
ensure
 LocalEntryDNS.define_singleton_method(:collect,original_collect)
 File.unlink(path) if File.file?(path)
end
puts 'PASS: regional grouping, strict DNS agreement, unknown separation, wire validation, DNS failure retention and atomic publish'
