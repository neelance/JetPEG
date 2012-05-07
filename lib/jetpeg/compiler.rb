verbose = $VERBOSE
$VERBOSE = false
require 'llvm/core'
$VERBOSE = verbose

LLVM_STRING = LLVM::Pointer(LLVM::Int8)

class FFI::Struct
  def inspect
    "{ #{members.map{ |name| "#{name}=#{self[name].inspect}" }.join ", "} }"
  end
end

class Hash
  def map_hash
    h = {}
    self.each_key do |key|
      h[key] = yield key, self[key]
    end
    h
  end
  
  def map_hash!
    self.each_key do |key|
      self[key] = yield key, self[key]
    end
  end
end

class Module
  def to_proc
    lambda { |obj| obj.is_a? self }
  end
end

module JetPEG
  class CompilationError < RuntimeError
    attr_reader :rule
    
    def initialize(msg, rule = nil)
      @msg = msg
      @rule = rule
    end
    
    def to_s
      "In rule \"#{@rule ? @rule.rule_name : '<unknown>'}\": #{@msg}"
    end
  end
  
  module Compiler
    class Builder < LLVM::Builder
      class LazyBlock
        def initialize(function, name)
          @function = function
          @name = name
        end
        
        def to_ptr
          @block ||= @function.basic_blocks.append @name
          @block.to_ptr
        end
      end
      
      attr_accessor :parser, :traced
      
      def create_block(name)
        LazyBlock.new self.insert_block.parent, name
      end
      
      def create_struct(llvm_type)
        llvm_type.null
      end
      
      def create_string_constant(string)
        constant = LLVM::ConstantArray.string string
        global = @parser.mod.globals.add constant.type, "strings.#{string[0..9]}"
        global.initializer = constant
        global.global_constant = 1
        global.linkage = :private
        self.gep global, [LLVM::Int(0), LLVM::Int(0)]
      end
            
      def extract_values(aggregate, count)
        count.times.map { |i| extract_value aggregate, i }
      end
      
      def insert_values(aggregate, values, indices)
        values.zip(indices).inject(aggregate) { |a, (value, i)| insert_value a, value, i }
      end
      
      def malloc(type, name = "")
        if @parser.malloc_counter
          old_value = self.load @parser.malloc_counter
          new_value = self.add old_value, LLVM::Int64.from_i(1)
          self.store new_value, @parser.malloc_counter
        end
        super
      end
      
      def free(pointer)
        if @parser.free_counter
          old_value = self.load @parser.free_counter
          new_value = self.add old_value, LLVM::Int64.from_i(1)
          self.store new_value, @parser.free_counter
        end
        super
      end
      
      def add_failure_reason(failed, position, reason)
        return if not @traced
        @parser.possible_failure_reasons << reason
        self.call @parser.llvm_add_failure_reason_callback, failed, position, LLVM::Int(@parser.possible_failure_reasons.size - 1)
      end
      
      def build_use_counter_increment(type, value)
        llvm_type = type.is_a?(ValueType) ? type.llvm_type : type
        case llvm_type.kind
        when :struct
          llvm_type.element_types.each_with_index do |element_type, i|
            next if not [:struct, :pointer].include? element_type.kind
            element = self.extract_value value, i
            build_use_counter_increment element_type, element
          end
          
        when :pointer
          return if llvm_type.element_type.kind != :struct or llvm_type.element_type.element_types.empty?
          
          increment_counter_block = self.create_block "increment_counter"
          continue_block = self.create_block "continue"
          
          not_null = self.icmp :ne, value, llvm_type.null, "not_null"
          self.cond not_null, increment_counter_block, continue_block
          
          self.position_at_end increment_counter_block
          additional_use_counter = self.struct_gep value, 1, "additional_use_counter"
          old_counter_value = self.load additional_use_counter
          new_counter_value = self.add old_counter_value, LLVM::Int64.from_i(1)
          self.store new_counter_value, additional_use_counter
          self.br continue_block

          self.position_at_end continue_block
        end
      end
    end
    
    class Recursion < RuntimeError
      attr_reader :expression
      
      def initialize(expression)
        @expression = expression
      end
    end
    
    Result = Struct.new :input, :return_value
    
    @@metagrammar_parser = nil
    
    def self.metagrammar_parser
      if @@metagrammar_parser.nil?
        begin
          File.open(File.join(File.dirname(__FILE__), "compiler/metagrammar.data"), "rb") do |io|
            metagrammar_data = JetPEG.realize_data(Marshal.load(io.read), self)
            @@metagrammar_parser = load_parser metagrammar_data, "compiler/metagrammar.jetpeg"
            @@metagrammar_parser.root_rules = [:choice, :grammar]
            @@metagrammar_parser.build
          end
        rescue Exception => e
          $stderr.puts "Could not load metagrammar:", e, e.backtrace
          exit
        end
      end
      @@metagrammar_parser
    end

    def self.compile_rule(code, filename = "grammar")
      expression = metagrammar_parser[:rule_expression].match code, output: :realized, class_scope: self, raise_on_failure: true
      expression.rule_name = :rule
      Parser.new({ "rule" => expression }, filename)
      expression
    rescue ParsingError => e
      raise CompilationError, "Syntax error in grammar: #{e}"
    end
    
    def self.compile_grammar(code, filename = "grammar")
      data = metagrammar_parser[:grammar].match code, output: :realized, class_scope: self, raise_on_failure: true
      parser = load_parser data, filename
      parser
    rescue ParsingError => e
      raise CompilationError, "Syntax error in grammar: #{e}"
    end
    
    def self.load_parser(data, filename)
      rules = data[:rules].each_with_object({}) do |element, h|
        expression = element[:expression]
        expression.rule_name = element[:rule_name].to_sym
        expression.parameters = element[:parameters] ? ([element[:parameters][:head]] + element[:parameters][:tail]).map{ |p| Parameter.new p.name } : []
        h[expression.rule_name] = expression
      end
      Parser.new rules, filename
    end
    
    def self.translate_escaped_character(char)
      case char
      when "r" then "\r"
      when "n" then "\n"
      when "t" then "\t"
      when "0" then "\0"
      else char
      end
    end
  end
end

require "jetpeg/parser"
require "jetpeg/values"

require "jetpeg/compiler/tools"
require "jetpeg/compiler/parsing_expression"
require "jetpeg/compiler/terminals"
require "jetpeg/compiler/composites"
require "jetpeg/compiler/labels"
require "jetpeg/compiler/functions"

require "jetpeg/compiler/optimizations/ruby_side_struct"
require "jetpeg/compiler/optimizations/leftmost_primary_rewrite"
