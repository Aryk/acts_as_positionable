# created for Mixbook.com by Aryk Grosz
# all right reserved.

module ActiveRecord
  module Acts #:nodoc:
    module Positionable  
      
      def self.append_features(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        
        # Usages:
        #   Pass in a block to configure the positions: ie
        #   
        #   acts_as_positionable do |p|
        #        p.number
        #        p.special(-1, "Front Cover")
        #        p.special(-2, "Back Cover", :sort_index => p.max_value + 1)
        #        p.special(-3, "Spine")
        #        p.group(-100, "Cover", [:front_cover, :back_cover, :spine])
        #   end
        #   
        #  Or utilize a position configuration from another class: 
        #
        #   acts_as_positionable(Page) <-- use the position configuration from this class.
        #   
        def acts_as_positionable(*args, &block) 
          options = args.extract_options!
          position_class = args.first || self
          
          class_variable_set(:@@position_column, options[:column] || "position")
          cattr_reader :position_column
          
          class_variable_set(:@@positions, ActiveRecord::Acts::Positionable::Positions.new(self))
          cattr_reader :positions 
          
          options[:extend] ||= position_class::PositionTypes if position_class && position_class.const_defined?("PositionTypes")
          positions.configure(block_given? ? block : position_class.positions.configuration, options)
          
          include ActiveRecord::Acts::Positionable::InstanceMethods
          extend ActiveRecord::Acts::Positionable::SingletonMethods 
          
          define_position_methods
        end
        
        def has_many_with_position(association_id, options = {}, &extension)
          has_many(association_id, options, &extension)
          reflection = reflections[association_id]
          positions = reflection.klass.positions
          
          reflection.options[:extend] << positions.has_many_extension
          
          delegate_methods = positions.has_many_extension.instance_methods.reject { |x| x=~/\?$/ } # don't delegate question methods 
          # prefix "number" types with the klass name for understandablity. So company.employee_number -> company.employees.number
          delegate(:number, :to => association_id, :prefix => positions.klass.to_s.demodulize.underscore) if delegate_methods.delete("number")
          delegate(*(delegate_methods << {:to => association_id}))
        end
        
      end   
          
      class Positions
        
        attr_reader :klass, :cache, :configuration, :extension, :has_many_extension
        
        def initialize(klass)
          @klass = klass
          @extension = Module.new
          @cache = {}
          
          # Since this is an association proxy extension, module cannot be anonymous, or else the association cannot be Marshal.dump'd.
          name = "#{klass.to_s.demodulize}#{klass.position_column.classify}HasManyAssociationExtension"
          mod = Module.new { define_method(klass.position_column.pluralize) { map { |x| x.position } } }
          @has_many_extension = silence_warnings { klass.parent.const_set(name, mod) }
        end
                
        # Lookup function for positions. 
        # Since position names are stored as symbols, self[:front_cover] is much faster then self["Front Cover"].
        def [](value) 
          case value
          when Integer then value > 0 ? (n=cache[:number]) && n[value] : cache[value]
          when Symbol then cache[value]
          when NilClass then nil
          when String then value=~/\d+/ ? self[value.to_i] : self[value.downcase.gsub(" ", "_").to_sym]
          when Array then Collection.new(value.map { |v| self[v] })
          when Types::Base then value
          else raise "Value must be an Integer or a Symbol, currently #{value.class}"
          end 
        end

        # Returns an array of symbols used to look up non-Number types.
        def symbols(include_number=true)
          cache.keys.find_all { |k| k.is_a?(Symbol) && (include_number || !self[k].is_a?(Types::Number)) }
        end

        def configure(configuration, options={})
          instance_variable_set(:@configuration, configuration)
          configuration.call(Builder.new(klass, options))
          extend_positions 
        end
        
        private 
        
        # Add methods from the position definition to each position.
        def extend_positions
          cache.values.each { |p| p.extend(extension) }
          # We freeze each of the positions EXCEPT the :number position, since
          # we adjust it's value and freeze later because the value is a range.
          cache.values.each { |p| p.freeze unless p.value.nil? }
        end
        
        class Collection < Array
          # Delegates to each positions #include? function.
          def include?(pos)
            any? { |position| position.include?(pos) }
          end
        end
              
        class Builder
        
          def initialize(klass, options={})
            @klass = klass
            @extend_module = options[:extend]
          end
          
          # Convenience
          def max_value
            Types::Number::MAX_VALUE
          end
        
          def method_missing(method, *args)
            classify = method.to_s.classify
            if @extend_module && @extend_module.constants.include?(classify)
              @extend_module.const_get(classify)
            else "#{Types}::#{method.to_s.classify}".constantize
            end.register(@klass, *args) 
          end
        end 
      
      end
         
      module SingletonMethods
        
        def define_position_methods
          # Use read_attribute to increase performance. about 3x faster than using super.
          define_method(position_column) do 
            positions[read_attribute(position_column)]
          end
          
          # Use write_attribute to increase performance.
          #   - Check to see if its a positive integer first to optimize since positive INTs are "number" type.
          define_method("#{position_column}=") do |p|
            write_attribute(position_column, p.is_a?(Integer) && p > 0 ? p : positions[p])
          end
        end 
        
        protected
        
        # Allows for (assuming :front_cover is a position) :
        #    Model.first :conditions => ["position=?", :front_cover]
        #    Model.first :conditions => {:position => :front_cover}
        #    Model.find_by_position(:front_cover)   <-- Aryk: pretty cool, huh?
        def quote_bound_value(value)
          super(expand_position(value))
        end
        
        private
        
        def attribute_condition(argument)
          super(expand_position(argument))
        end
        
        # Expands the position value for conditions. 
        def expand_position(value)
          return value.map { |v| expand_position(v) } if value.is_a?(Array)
          value = positions[value] if value.is_a?(Symbol)
          value = value.to_expanded_i if value.is_a?(ActiveRecord::Acts::Positionable::Types::Base)
          value
        end
        
      end
      
      module InstanceMethods
      end 

      # Follows similar design pattern to URI (module) and URI::HTTP, URI::HTTPS, etc.
      module Types
        class Base   
          
          extend ActiveSupport::Memoizable
          
          # Aryk: I could have made it so that this acts as a proxy class to the
          # value of the position, but after experimenting it doesn't add that much benefit. If
          # anything, it might be confusing because it will not work as an
          # Integer in the places where it is really important (ie case
          # statements).
          
          class_inheritable_accessor :level
          self.level = 10 # very low priority (0 is highest)
    
          attr_reader :value, :name
          alias :to_i :value 
          alias :to_expanded_i :to_i # entire inclusive set of position values.
      
          def initialize(value, name, options={})
            @value = value
            @name = name 
          end
      
          class << self
        
            def register(klass, value, *args)  
              position = new(value, *args)
              [value, position.to_sym].map { |key| klass.positions.cache[key] = position } 
              define_methods(klass, position)            
            end 
        
            def define_methods(klass, position)
              [:position, :model, :has_many].each do |object_type|
                ["write", "read", "question"].each do |method_type|
                  method_name = "define_#{object_type}_#{method_type}_method"
                  send(method_name, klass, position) if respond_to?(method_name)
                end          
              end
              {:to_i => 0, :name => "", :short_name => "", :keyword => nil}.each do |method_name, default|
                delegate_method_to_position(method_name, klass, default) unless klass.column_names.include?(method_name.to_s)
              end
            end
        
            # Define the position questioner method. ie. model.position.cover? 
            def define_position_question_method(klass, position)  
              evaluate_method("def #{position.to_sym}? ; #{define_question_code(klass, position)} ; end", klass.positions.extension) 
            end
        
            def define_model_question_method(klass, position) 
              delegate_method_to_position("#{position.to_sym}?", klass) # ie. model.cover? 
            end 
            
            def define_model_write_method(klass, position) 
              evaluate_method(%{def #{position.to_sym}=(v) v==true ? self.#{klass.position_column} = #{position.value} : raise('Setter only accepts "true".') end}, klass)
            end
            
            def define_has_many_read_method(klass, position)
              functions = position.is_a?(Primitive) ? ["detect", "find_by_#{klass.position_column}"] : ["find_all", "find_all_by_#{klass.position_column}"]
              method_definition = "def #{sym = position.to_sym}() @#{sym} ||= loaded? ? @target.#{functions[0]} { |x| x.#{sym}? } : #{functions[1]}(#{sym.inspect}) end"
              evaluate_method(method_definition, klass.positions.has_many_extension) 
            end
            
            def define_has_many_question_method(klass, position)
              evaluate_method("def #{position.to_sym}?(*args) !!#{position.to_sym}(*args) end", klass.positions.has_many_extension) 
            end
            
            # Defines method to check if it is or falls within another position.
            # ie. position.odd?
            def define_question_code(klass, position)
              "@value==#{position.value}"
            end
        
            private
        
            def delegate_method_to_position(method_name, klass, default=:nil) 
              default = method_name.to_s[-1..-1]=="?" ? false : nil if default==:nil # want question methods to return false.
              evaluate_method(%{def #{method_name}(*args) ; (p=#{klass.position_column}).nil? ? #{default.inspect} : p.#{method_name}(*args) ; end}, klass)
            end
        
            # Evaluate the definition for an position related method
            def evaluate_method(method_definition, klass)
              klass.class_eval(method_definition, __FILE__, __LINE__)
            end  
      
          end
      
          def to_sym
            name.downcase.gsub(" ", "_").to_sym
          end 
          memoize :to_sym
          alias :keyword :to_sym 
      
          def <=>(position)
            sort_index <=> position.sort_index
          end
          
          def include?(position)
            self==position
          end
      
          def ==(position)
            to_i==position.to_i
          end
          
          # Delegates to ==
          def eql?(position)
            self==position
          end
          
          # Delegates to #to_i.
          def hash
            to_i.hash
          end
      
          def sort_index
            @sort_index || raise("Please specify the @sort_index for this position: #{value}.")
          end
  
          # Used when we don't want to take up much space.
          # This doesn't necessarily have to be unique.
          def short_name 
            name.gsub(/([A-Z])[^A-Z]+/, '\1')
          end
          memoize :short_name
      
          def titleize
            "The #{name}"
          end 
          memoize :titleize
      
          private
      
          # Forwards any missing method call to the value.
          def method_missing(method, *args) 
            if block_given?
              @value.send(method, *args)  { |*block_args| yield(*block_args) }
            else
              @value.send(method, *args)
            end
          end
      
        end
        class Primitive < Base
          self.level = 0
      
          def initialize(value, name, options={})
            @sort_index = options[:sort_index] || value
            super
          end      
      
        end
        class Complex < Base 
      
          self.level = 1
      
          def include?(position)
            raise("include? must be implemented in subclasses.")
          end
          
          def sort_index
            raise("complex positions cannot be sorted.")
          end
          
        end
        class Number < Primitive 
      
          MAX_VALUE = 32767 # smallint limit.
          
          DEFAULT_NAME = "Position"
       
          alias :sort_index :value
          alias :keyword :value
      
          def initialize(value, name=DEFAULT_NAME)
            super
          end
      
          def name
            "#{@name} #{@value}"
          end
      
          def short_name
            @value.to_s
          end
      
          def titleize
            "Page #{@value}"
          end
                    
          def include?(position)
            value.nil? ? position.to_i > 0 : super
          end
          
          # Spawn off a new number. We don't memoize the object because caching
          # all the methods on the object eats CPU and this object dissapears
          # after the request anyways.
          def [](value) 
            obj = clone
            obj.instance_variable_set(:@value, value)
            obj.freeze_without_memoizable 
            obj
          end
      
          class << self
        
            # Only can get called once to support normal numbers greater than 0
            def register(klass)
              position = returning(new(nil, klass.to_s.split("::").last)) { |p| p.class_eval %{def to_sym ; :number ; end} }       
              klass.positions.cache[position.to_sym] = position
              define_methods(klass, position)
            end
      
            def define_has_many_read_method(klass, position)
              condition_code = %{(number ? ["#{klass.position_column}=?", number] : "#{klass.position_column} > 0")}
              number_check_code = %{return nil if number && number <= 0}
              method_definition = "def #{sym = position.to_sym}(number=nil) #{number_check_code} ; loaded? ? @target.detect { |x| x.#{sym}?(number) } : first(:conditions => #{condition_code}) end"
              evaluate_method(method_definition, klass.positions.has_many_extension) 
            end
            
            # Define the position questioner method. ie. model.position.cover? 
            def define_position_question_method(klass, position)  
              evaluate_method("def #{position.to_sym}?(number=nil) #{define_question_code(klass, position)} end", klass.positions.extension) 
            end
            
            # Defines method to check if it is or falls within another position.
            # ie. position.odd?
            def define_question_code(klass, position) 
              "is_a?(#{name}) && (!number || number==@value)"
            end
        
            def define_position_read_method(klass, position)
              evaluate_method(%{def #{position.to_sym} ; @value if number? ; end}, klass.positions.extension)
            end
        
            def define_model_write_method(klass, position)
              evaluate_method(%{def #{position.to_sym}=(v) self.#{klass.position_column} = v && positions[v].number? ? v : nil end}, klass)
            end
        
            def define_model_read_method(klass, position)
              delegate_method_to_position(position.to_sym, klass) # ie. model.cover?  
            end
        
          end
        end
        class Special < Primitive 
        end
        class Group < Complex
          include Enumerable
      
          attr_reader :target
      
          def initialize(value, name, target)
            raise("Target array required for Group position") unless target.is_a?(Array)
            @target = target
            super(value, name)
          end 
          
          def self.register(klass, value, *args)   
            args[1] = klass.positions[args[1]] # make sure the target get stored as position objects.
            super
          end

          # To keep function fast, comparison is done on integers.
          def include?(position)
            to_expanded_i.include?(position.to_i)
          end          
          
          def to_expanded_i
            to_expanded_set.to_a 
          end 
          
          # Used to create extremely fast lookups (see #define_question_code)
          def to_expanded_set
            (target.map { |x| x.to_i } << to_i).to_set  # include the group value as well
          end
          memoize :to_expanded_set
      
          def each
            target.each { |position| yield(position) }
          end
      
          def self.define_question_code(klass, position)
            # Aryk: After benchmarking I found that using the set (hash-lookup)
            # was fast for larger steps, but arrays were better for smallerones.
            position.to_expanded_i.size > 100 ?
              %{#{klass}.positions[#{position.value}].to_expanded_set.include?(@value)} :
              "#{position.to_expanded_i.inspect}.include?(@value)"  
          end 
        
        end
        class Pattern < Complex
          self.level = 2
      
          attr_reader :question_code
      
          def initialize(value, name, question_code)
            @question_code = question_code
            super(value, name)
          end
                
          def self.define_question_code(klass, position)
            "(number? && #{position.question_code}) || (#{super})"
          end
        end
        class Function < Complex
          self.level = 3 
        end
    
      end  # Position 
    end  # Types
        
  end 
end
ActiveRecord::Base.send(:include, ActiveRecord::Acts::Positionable) 
