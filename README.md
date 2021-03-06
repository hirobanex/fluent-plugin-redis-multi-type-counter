[![Stories in Ready](https://badge.waffle.io/HeartSaVioR/fluent-plugin-redis-multi-type-counter.png?label=ready)](https://waffle.io/HeartSaVioR/fluent-plugin-redis-multi-type-counter)
# Redis multi-type counter plugin for fluent [![Build Status](https://travis-ci.org/HeartSaVioR/fluent-plugin-redis-multi-type-counter.png)](https://travis-ci.org/HeartSaVioR/fluent-plugin-redis-multi-type-counter)

fluent-plugin-redis-multi-type-counter is a fluent plugin to count-up/down redis keys, hash, sorted set.

# Installation

fluent-plugin-redis-multi-type-counter is hosted by [RubyGems.org](https://rubygems.org/).

    $fluent-gem install fluent-plugin-redis-multi-type-counter

# Configuration

    <match redis_counter.**>
      type redis_counter

      host localhost
      port 6379

      # database number is optional.
      db_number 0        # 0 is default

      # match condition
      # this pattern matches {"status": "200", "url": "http://foo.example.com"} and then,
      # increment Redis key "foo-status2xx" by calling Redis::incrby( "foo-status2xx", 1 ).
      <pattern>
        match_status ^2[0-9][0-9]$        # matches with {"status": "200", ...
        match_url ^http:\/\/foo\.         # matches with {"url": "http://foo.example.com", ...
        count_key foo-status2xx           # key-name for Redis
        count_value 1                     # count-up amount(default: 1, negative value is allowed)
      </pattern>

      # time-dependent redis keyname
      # for example, "foo-status2xx-%Y-%m-%d" will be formatted to "foo-status2xx-2012-06-21".
      # rules for placeholder(%Y, etc.) is similar to out_file plugin.
      <pattern>
        match_status ^2[0-9][0-9]$
        count_key_format foo-statux2xx-%d
        localtime                         # time-zone(default: localtime, it can be "utc" or "localtime")
      </pattern>

      # you can also use values from the matched JSON record in the key name, by using the 
      # syntax foo%_{key1}-%_{key2}, where key1 and key2 are keys in the JSON record that 
      # was received by fluentd.
      # for example, "customer:%_{customer_id}:status2xx" will be formatted to 
      # "customer:123:status2xx" if the JSON record contains a key named "customer_id" 
      # with value 123, like so: {"status": 200, "customer_id": 123 ... }.
      # these can be combined with the time formatting options in the previous example.
      <pattern>
        match_status ^2[0-9][0-9]$
        count_key_format customer:%_{customer_id}:status2xx-%Y-%m-%d
      </pattern>

      # you can just store value to list (not counting on, it's something awkward) by store_list to true
      # note that you cannot use store_list with hash or zset
      <pattern>
        match_status ^2[0-9][0-9]$
        count_key_format customer:%_{customer_id}:status2xx-%Y-%m-%d
        store_list true
      </pattern>

      # you can also sum up key in hash, by configuring count_hash_key_format
      # syntax is same to count_key_format
      # for example, {"custom_id": 123, "date": "20131219" ...}.
      # HINCRBY item_count:123 20131219 1
      <pattern>
        count_key_format item_count:%_{item_id}
        count_hash_key_format %_{date}
      <pattern>

      # you can also sum up key in sorted set(zset), by configuring count_zset_key_format
      # syntax and usage is same to count_hash_key_format
      # for example, {"custom_id": 123, "date": "20131219" ...}.
      # ZINCRBY item_count:123 1 20131219
      <pattern>
        count_key_format item_count:%_{item_id}
        count_zset_key_format %_{date}
      <pattern>

      # you can also sum up specified key with count_value_key option.
      # for example, {"count": 321, "customer_id": 123 ... }.
      # INCRBY item_count:123 321.
      <pattern>
        count_key_format item_count:%_{item_id}
        count_value_key count
      </pattern>
    </match>

# Example

prepare a conf file ("fluent.conf") in current directory like this:

    <source>
      type forward
    </source>
    <match debug.**>
      type redis_counter
      host localhost
      port 6379
      db_number 0
      <pattern>
        match_status ^2[0-9][0-9]$
        match_url ^http:\/\/foo\.
        count_key foo
      </pattern>
    </match>

run commands for test:

    $redis-server 2>&1 >/dev/null &
    [1] 879
    $echo del foo | redis-cli -h localhost -p 6379 -n 0
    (integer) 0
    $fluentd -c ./fluent.conf 2>&1 >/dev/null &
    [2] 889
    $echo {\"status\": \"200\", \"url\": \"http://foo.example.com\"} | fluent-cat debug
    $echo {\"status\": \"500\", \"url\": \"http://foo.example.com\"} | fluent-cat debug
    $kill -s HUP 889
    $echo get foo | redis-cli -h localhost -p 6379 -n 0
    "1"

# Copyright
- Copyright © 2014      Jungtaek Lim
- Copyright © 2012-2014 Buntaro Okada
- Copyright © 2011-2012 Yuki Nishijima

# License
- Apache License, Version 2.0
