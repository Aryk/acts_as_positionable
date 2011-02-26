require 'test_helper'

AAP = ActiveRecord::Acts::Positionable

ActiveRecord::Schema.define do  
  create_table :aap_employees, :force => true do |t|
    t.integer :corporate_position  
    t.integer :company_id  
  end  
end
ActiveRecord::Schema.define do  
  create_table(:aap_companies, :force => true) {}
end

class ActsAsPositionableTest < ActiveSupport::TestCase
  
  class Employee < ActiveRecord::Base
    self.table_name = "aap_employees"
    belongs_to :company, :class_name => "ActsAsPositionableTest::Company"
    acts_as_positionable(:column => "corporate_position") do |p|
      # A normal number will refer to the "normal" employees for the purpose of this test...
      p.number 
      
      p.special(-1, "CEO")
      p.special(-2, "CTO")
      p.special(-3, "CFO")
      p.special(-4, "VP Corporate Development")
      p.special(-5, "VP Marketing", :sort_index => 1000000)  # should come at end
      p.group(-100, "Executive Team", [:ceo, :cto, :cfo])
      p.pattern(-200, "Odd", "@value.modulo(2)==1")
    end
  end
  class Company < ActiveRecord::Base
    self.table_name = "aap_companies"
    has_many_with_position(:employees, :class_name => "ActsAsPositionableTest::Employee")
  end
  
  class AAPTestCase < ActiveSupport::TestCase
    
    purge :aap_employees
      
    def setup
      @klass = Employee
      @parent_class = Company
      @parent = Company.new.saved_record!
      @instance = @klass.new(:corporate_position => 3, :company => @parent)
      @positions = @klass.positions
      @position_symbol = @@position_symbol ||= @positions.symbols(false).rand 
      @position = @positions[@position_symbol] 
      @value = @position.value
    end
    
  end 
      
  class HasManyWithPositionTest < AAPTestCase
    
    POSITIONS = [:ceo, :cto, 1, 2, 3, :executive_team]
    
    READ_TEST = {
      [:number, 4] => nil,
      [:number, 3] => 3,
      [:ceo]       => :ceo,
      [:cto]       => :cto,
      [:executive_team] => [:ceo, :cto, :executive_team] }
   
    # For example @company.employees.ceo -> employee instance that is ceo.
    test "read when loaded?" do 
      @parent.connection.expects(:execute).never
      READ_TEST.each do |args, result|
        assert_equal result, keywords(@parent.employees.send(*args)) 
      end 
      assert @parent.employees.number.corporate_position.to_i > 0, "number without arg should return a number position"
    end
    
    # For example @company.employees.ceo -> employee instance that is ceo.
    test "read when not loaded?" do 
      @parent.reload
      READ_TEST.each do |args, result|
        assert_equal result, keywords(@parent.employees.send(*args))
      end 
      assert @parent.employee_number.corporate_position.to_i > 0, "number without arg should return a number position"
    end
        
    # For example @company.ceo -> employee instance that is ceo.
    test "read delegate when loaded?" do 
      @parent.connection.expects(:execute).never
      READ_TEST.each do |args, result|
        args = returning(args.dup) { |a| a[0] = :employee_number if a[0]==:number }
        assert_equal result, keywords(@parent.send(*args))
      end 
    end
        
    test "question when loaded?" do  
      @parent.connection.expects(:execute).never
      { [:number?, 4] => false,
        [:number?, 3] => true,
        [:ceo?]       => true,
        [:number?, 0] => false,
        [:number?]    => true,
        [:executive_team?] => true
      }.each do |args, result|
        assert_equal result, @parent.employees.send(*args)
      end 
    end
              
    def setup
      super
      @parent = @parent_class.create!
      @employees = POSITIONS.map do |position|
        @klass.create!(:corporate_position => position)
      end
      @parent.employees << @employees
      @parent.employees.loaded
    end
    
    def keywords(records)
      case records
      when ActiveRecord::Base  then records.corporate_position.keyword
      when Array then records.map { |p| keywords(p) }
      else records
      end
    end
        
  end
  class InstanceMethodsTest < AAPTestCase
  
    test "sanitize_sql for positions" do  
      @instance = @klass.create!(:corporate_position => @position_symbol)
      assert @instance.corporate_position.send("#{@position_symbol}?")
    end
  
    test "position=" do 
      {"3" => 3, nil => nil, 19 => 19, 0 => nil, :foo => nil,
        @positions[@position_symbol] => @positions[@position_symbol].to_i,
        @position_symbol => @positions[@position_symbol].to_i, 
      }.each do |position, result| 
        @instance.corporate_position = position 
        assert_equal result, @instance["corporate_position"]
      end
    end
    
    test "position= marks as dirty" do 
      @instance.corporate_position = 77
      assert @instance.corporate_position_changed? 
      
      @instance.send(:changed_attributes).clear
      
      @instance.corporate_position = 88
      assert @instance.corporate_position_changed? 
      assert_equal 77, @instance.corporate_position_was
    end
  
    test "position" do 
      @instance["corporate_position"] = 4
      @positions.expects(:[]).with(4)
      @instance.corporate_position
    end
  
    test "position with nil" do 
      assert_nil @klass.new.corporate_position
    end 
  
    test "position question methods" do 
      @instance.corporate_position = :ceo
      {"ceo?" => true, "cfo?" => false, "vp_corporate_development?" => false, "number?" => false}.each do |method, result|
        assert_equal result, @instance.send(method)
      end
    end
    
  end
  class SingletonMethodsTest < AAPTestCase 
    
    test "position assigned correctly" do 
      assert_equal @position, @instance.corporate_position
    end
    
    test "find_by_position" do 
      assert_equal @instance, @klass.find_by_corporate_position(@position_symbol)
      assert_equal @instance, @klass.find_by_corporate_position(@position)
    end
    
    test "find_all_by_position" do 
      assert_equal [@instance], @klass.find_all_by_corporate_position(@position_symbol)
      assert_equal [@instance], @klass.find_all_by_corporate_position(@position)
      assert_equal [@instance, @instance1], @klass.find_all_by_corporate_position([@position_symbol, @position_number])
    end
    
    test "conditions as array" do
      condition = @position.to_expanded_i.is_a?(Array) ? "corporate_position IN (?)" : "corporate_position = ?"
      assert_equal @instance, @klass.first(:conditions => [condition, @position_symbol])
      assert_equal @instance, @klass.first(:conditions => [condition, @position])
    end
    
    test "conditions as hash" do 
      assert_equal @instance, @klass.first(:conditions => {:corporate_position => @position_symbol})
      assert_equal @instance, @klass.first(:conditions => {:corporate_position => @position})
    end 
    
    def setup 
      super
      @instance = @klass.create!(:corporate_position => @position_symbol)
      @instance1 = @klass.create!(:corporate_position => (@position_number = 4))
    end
    
  end
  class PositionsTest < AAPTestCase 
    
    test "[] with position" do 
      # assert_same doesnt work because it will get proxied.
      assert_equal @position.object_id, @positions[@position].object_id, "Should return the same object."
    end 
    
    test "[]" do 
      {4 => 4, -1 => -1, nil => nil,
        @position_symbol => @value,        
        [@position_symbol, 2, 3] => [@position.to_i, 2, 3],
        @positions[@position_symbol] => @value,
        @position_symbol.to_s.titleize => @value,
        @position_symbol.to_s => @value
      }.each do |value, expected|
        position = @positions[value]  
        position = position.map(&:to_i) if position.is_a?(Array)
        assert_equal expected, position 
      end
    end 
    
    
    class CollectionTest < AAPTestCase 
      
      test "include?" do
        {[:executive_team, :vp_corporate_development] => true, :ceo => true, :executive_team => true, 
          :vp_marketing => false}.each do |args, result|
          assert_equal result, @positions[args].include?(@positions[:ceo])
        end
        {[:executive_team, :vp_corporate_development] => true, :ceo => false, :executive_team => true, 
          :vp_marketing => false}.each do |args, result|
          assert_equal result, @positions[args].include?(@positions[:executive_team])
        end
        {[:number, :vp_corporate_development] => true, 5 => false, [4] => true, 
          :vp_marketing => false}.each do |args, result|
          assert_equal result, @positions[args].include?(4)
        end
      end
      
    end
  end
  
  module Types 
    class TypeTestCase < AAPTestCase

      # A little confusing here, but because we are testing the different
      # position types, I moved "@klass" to be the actual position type class
      # instead of "Employee". I moved "Employee" to @model. 
      def setup
        super
        @model = Employee
        @klass = "#{AAP}::Types::#{self.class.name.split("::").last.gsub("Test", "")}".constantize rescue nil
        @value = 8
        @instance = @klass.new(@value, "Foo Bar") rescue nil # For Group we have a third argument.
        @model_instance = @model.new(:corporate_position => @instance)
      end 
      
    end
    
    class BaseTest < TypeTestCase
      
      test "eql?" do 
        hash =  {@positions[4] => 1, @positions[5] => 2}
        assert_equal 1, hash[@positions[4]]
        assert_equal 2, hash[@positions[5]]
        assert_equal nil, hash[@positions[6]] 
        assert_not_empty [@positions[4]] & [@positions[4]]
      end
      
      test "array operations" do 
        first = @positions[[:cfo, :cto, :ceo]]
        second = @positions[[:cfo, :cto, :ceo, 2, 5, 12, 31, :vp_marketing]]
        assert_empty first - second
        assert_equal first, (first & second)
        assert_equal second, (first | second)
      end
      
      test "level" do 
        assert_kind_of Integer, @klass.level
        assert_kind_of Integer, @instance.level
      end
      
      test "to_i" do 
        assert_equal @instance.value, @instance.to_i
      end
      
      test "titleize" do 
        assert_equal "The Foo Bar", @instance.titleize
      end
      
      test "to_sym" do 
        assert_equal :foo_bar, @instance.to_sym
      end
      
      test "keyword" do 
        assert_equal :foo_bar, @instance.keyword
      end
      
      test "==" do 
        assert_true @instance==@value, "Should be able to test directly with value"
        assert_true @instance==@instance.clone, "Should be able to test directly with value"
      end
      
      test "sort" do  
        ordered = @positions[[:cfo, :cto, :ceo, 2, 5, 12, 31, :vp_marketing]]
        unordered = ordered.shuffle
        assert_equal ordered, unordered.sort
      end
      
      test "short_name" do 
        assert_equal "FB", @instance.short_name
      end
      
      test "model methods for nil position" do 
        @model_instance = @model.new
        assert_nil @model_instance.corporate_position
        assert_false @model_instance.ceo?
        assert_false @model_instance.number?
      end
      
      test "model write" do 
        @model_instance.ceo = true
        assert_equal @positions[:ceo], @model_instance["corporate_position"]
      end
      
      test "model question" do 
        assert_false @model_instance.ceo?
        @model_instance.ceo = true
        assert_true @model_instance.ceo? 
      end
      
      test "model delegate methods defaults" do 
        @model_instance = @model.new
        {:to_i => 0, :name => "", :short_name => "", :keyword => nil}.each do |method, default|
          assert_equal default, @model_instance.send(method), "When no position set, #{method} should return #{default}"
        end
      end
      
    end
    class PrimitiveTest < TypeTestCase
      
      test "sort_index" do  
        assert_equal @value, @instance.sort_index
      end 
      
      test "sort_index with :sort_index option" do
        @instance = @klass.new(@value, @name, :sort_index => 99)
        assert_equal 99, @instance.sort_index
      end
      
    end
    class ComplexTest < TypeTestCase
      
      # Complex positions don't have a sort index (for now).
      test "sort_index raises exception" do 
        assert_raise(RuntimeError) { @instance.sort_index }
      end
    end
    class NumberTest < TypeTestCase
      
      test "define_methods" do 
        {@position_symbol => false, 1 => true, 544 => true, @position.value => false}.each do |position, result| 
          assert_equal result, @positions[position].number?
        end
        {1 => 1, 544 => 544, @position.value => nil, @position_symbol => nil}.each do |position, result|
          assert_equal result, @positions[position].number
        end
      end
      
      test "page reader methods" do 
        {nil => nil, 3 => 3, -1 => nil}.each do |number, result|
          @model_instance["corporate_position"] = number
          assert_equal result, @model_instance.number
        end
      end
      
      test "page writer methods" do  
        {nil => nil, 3 => 3, -1 => nil}.each do |number, result|
          @model_instance.number = number
          assert_equal result, @model_instance["corporate_position"]
        end
      end
      
      test "include?" do 
        {3 => true, 0 => false, 1003434 => true, -1 => false}.each do |pos, result|
          assert_equal result, @number_position.include?(pos)
        end
        {@value => true, 0 => false, 1003434 => false, -1 => false}.each do |pos, result|
          assert_equal result, @instance.include?(pos)
        end
      end
      
      test "name" do 
        assert_equal "Employee 8", @instance.name
      end
      
      test "short_name" do 
        assert_equal "8", @instance.short_name
      end
      
      test "titleize" do 
        assert_equal "Page 8", @instance.titleize
      end
      
      test "frozen?" do 
        assert_true @instance.frozen?, "Number should be frozen so their value can't be tampered with."
      end
      
      test "position question" do 
        assert_true @instance.number?
        assert_true @instance.number?(@value)
        assert_false @instance.number?(@value + 1)
      end
      
      test "model question" do 
        assert_true @model_instance.number?
        assert_true @model_instance.number?(@value)
        assert_false @model_instance.number?(@value + 1)
      end
      
      def setup
        super
        @number_position = @positions[:number]
        @instance = @number_position[@value] 
      end
      
    end
    class SpecialTest < TypeTestCase
      
      test "titleize" do 
        assert_equal "The CEO", @instance.titleize
      end
      
      def setup
        super
        @instance = @positions[:ceo] 
      end
      
    end
    class GroupTest < TypeTestCase      
      
      test "titleize" do 
        assert_equal "The Executive Team", @instance.titleize, "Should be pluralized"
      end
      
      test "question methods" do 
        {@instance.value => true, 4 => false, @position_symbol => true}.each do |position, result|
          assert_equal result, @positions[position].send("#{@position_symbol}?")
        end
      end
      
      test "model methods" do 
        assert_true @model_instance.executive_team?
        assert_true @positions[:ceo].executive_team?
      end
      
      test "to_expanded_i" do 
        assert_same_set [-1, -2, -3, -100], @instance.to_expanded_i, "Should include group position as well."
      end
      
      def setup 
        super
        @position_symbol = :executive_team
        @instance = @positions[@position_symbol] # group position 
        @model_instance.corporate_position = @instance
      end
      
    end
    class PatternTest < TypeTestCase    
      
      test "question methods" do 
        {1 => true, 1001 => true, 4 => false, -3 => false, 3 => true, 21 => true }.each do |position, result|
          assert_equal result, @positions[position].odd?, "#{position} was supposed to be #{result}"
        end
      end 
      
    end
  end    
end