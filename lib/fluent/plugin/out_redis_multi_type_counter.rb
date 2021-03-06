module Fluent
  class RedisMultiTypeCounterOutput < BufferedOutput
    Fluent::Plugin.register_output('redis_multi_type_counter', self)
    attr_reader :host, :port, :db_number, :password, :redis, :patterns

    config_param :max_pipelining, :integer, :default => 1000

    def initialize
      super
      require 'redis'
      require 'msgpack'
    end

    def configure(conf)
      super
      @host = conf.has_key?('host') ? conf['host'] : 'localhost'
      @port = conf.has_key?('port') ? conf['port'].to_i : 6379
      @password = conf.has_key?('password') ? conf['password'] : nil
      @db_number = conf.has_key?('db_number') ? conf['db_number'].to_i : nil
      @patterns = []
      conf.elements.select { |element|
        element.name == 'pattern'
      }.each { |element|
        begin
          @patterns << Pattern.new(element)
        rescue RedisMultiTypeCounterException => e
          raise Fluent::ConfigError, e.message
        end
      }
    end

    def start
      super
      @redis = Redis.new(
        :host => @host, :port => @port,
        :password => @password,
        :thread_safe => true, :db => @db_number
      )
    end

    def shutdown
      @redis.quit
    end

    def format(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def write(chunk)
      table = {}
      table.default = 0
      chunk.open { |io|
        begin
          MessagePack::Unpacker.new(io).each { |message|
            (tag, time, record) = message
            @patterns.select { |pattern|
              pattern.is_match?(record)
            }.each{ |pattern|
              count_key = pattern.get_count_key(time, record)
              count_hash_key = pattern.get_count_hash_key(record)
              count_zset_key = pattern.get_count_zset_key(record)
              store_list = pattern.store_list

              key = RecordKey.new(count_key, count_hash_key, count_zset_key, store_list)
			  if store_list
			    if table[key] == 0
				  table[key] = []
				end

			    table[key] << pattern.get_count_value(record)
			  else
                table[key] += pattern.get_count_value(record)
		      end
            }
          }
        rescue EOFError
          # EOFError always occured when reached end of chunk.
        end
      }

      table.each_pair.select { |key, value|
        value != 0
      }.each_slice(@max_pipelining) { |items|
        @redis.pipelined do
          items.each do |key, value|
            if key.count_hash_key != nil
              @redis.hincrby(key.count_key, key.count_hash_key, value)
            elsif key.count_zset_key != nil
              @redis.zincrby(key.count_key, value, key.count_zset_key)
            else
			  if key.store_list
			    @redis.rpush(key.count_key, value)
              else
                @redis.incrby(key.count_key, value)
		      end
            end
          end
        end
      }
    end

    class RecordKey
      attr_reader :count_key, :count_hash_key, :count_zset_key, :store_list

      def initialize(count_key, count_hash_key, count_zset_key, store_list)
        @count_key = count_key
        @count_hash_key = count_hash_key
        @count_zset_key = count_zset_key
        @store_list = store_list
      end

      def hash
        hash_key = ""

        keys = [@count_key, @count_hash_key, @count_zset_key]
        keys.select { |key| 
          key != nil
        }.each { |key|
          hash_key += ("@@@@" + key)
        }

        hash_key.hash
      end

      def eql?(other)
        return @count_key.eql?(other.count_key) && @count_hash_key.eql?(other.count_hash_key) && 
          @count_zset_key.eql?(other.count_zset_key)
      end
    end

    class RedisMultiTypeCounterException < Exception
    end

    class RecordValueFormatter
      attr_reader :format
      def initialize(format)
        @format = format
      end

      CUSTOM_KEY_EXPRESSION_RE = /(%_\{([^\}]+)\})/

      def key(record)
        @format.gsub(CUSTOM_KEY_EXPRESSION_RE) do |s|
          record[$2]
        end
      end
    end

    class Pattern
      attr_reader :matches, :count_value, :count_value_key, :store_list

      def initialize(conf_element)
        if !conf_element.has_key?('count_key') && !conf_element.has_key?('count_key_format')
          raise RedisMultiTypeCounterException, '"count_key" or "count_key_format" is required.'
        end
        if conf_element.has_key?('count_key') && conf_element.has_key?('count_key_format')
          raise RedisMultiTypeCounterException, 'both "count_key" and "count_key_format" are specified.'
        end

        if conf_element.has_key?('count_key')
          @count_key = conf_element['count_key']
        else
          if conf_element.has_key?('localtime') && conf_element.has_key?('utc')
            raise RedisMultiTypeCounterException, 'both "localtime" and "utc" are specified.'
          end
          is_localtime = true
          if conf_element.has_key?('utc')
            is_localtime = false
          end
          @count_key_format = [conf_element['count_key_format'], is_localtime]
          @record_formatter_for_count_key = RecordValueFormatter.new(@count_key_format[0])
        end

        @store_list = false
        if conf_element.has_key?('store_list') && conf_element['store_list'].downcase == 'true'
          @store_list = true
        end

        if @store_list && (conf_element.has_key?('count_hash_key_format') ||
            conf_element.has_key?('count_zset_key_format'))
          raise RedisMultiTypeCounterException, 'store_list is true, it should be normal type, not hash or zset'
        end

        if conf_element.has_key?('count_hash_key_format') && conf_element.has_key?('count_zset_key_format')
          raise RedisMultiTypeCounterException, 'both "count_hash_key_format" "count_zset_key_format" are specified.'
        end

        if conf_element.has_key?('count_hash_key_format')
          @count_hash_key_format = conf_element['count_hash_key_format']
          @record_formatter_for_count_hash_key = RecordValueFormatter.new(@count_hash_key_format)
        else
          @count_hash_key_format = nil
        end

        if conf_element.has_key?('count_zset_key_format')
          @count_zset_key_format = conf_element['count_zset_key_format']
          @record_formatter_for_count_zset_key = RecordValueFormatter.new(@count_zset_key_format)
        else
          @count_zset_key_format = nil
        end

        if conf_element.has_key?('count_value_key')
          @count_value_key = conf_element['count_value_key']
        else
          @count_value = 1
          if conf_element.has_key?('count_value')
            begin
              @count_value = Integer(conf_element['count_value'])
            rescue
              raise RedisMultiTypeCounterException, 'invalid "count_value", integer required.'
            end
          end
        end

        @matches = {}
        conf_element.each_pair.select { |key, value|
          key =~ /^match_/
        }.each { |key, value|
          name = key['match_'.size .. key.size]
          @matches[name] = Regexp.new(value)
        }
      end

      def is_match?(record)
        @matches.each_pair{ |key, value|
          if !record.has_key?(key) || !(record[key] =~ value)
            return false
          end
        }
        return true
      end

      def get_count_key(time, record)
        if @count_key_format == nil
          @count_key
        else
          count_key = @record_formatter_for_count_key.key(record)
          formatter = TimeFormatter.new(count_key, @count_key_format[1])
          formatter.format(time)
        end
      end

      def get_count_hash_key(record)
        if @count_hash_key_format == nil
          return nil
        else
          return @record_formatter_for_count_hash_key.key(record)
        end
      end

      def get_count_zset_key(record)
        if @count_zset_key_format == nil
          return nil
        else
          return @record_formatter_for_count_zset_key.key(record)
        end
      end

      def get_count_value(record)
        if @count_value_key
          ret = record[@count_value_key] || 0
          return ret.kind_of?(Integer) ? ret : 0
        else
          if @count_value
            return @count_value
          end
        end
      end
    end
  end
end
