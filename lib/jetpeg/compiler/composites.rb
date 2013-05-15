module JetPEG
  module Compiler
    class Sequence < ParsingExpression
      leftmost_leaves :first_child

      def build(builder, start_input, modes, failed_block)
        '
          *_entry:
            first_end_input, first_has_return_value = $build first_child, _start_input, *_failed
            _end_input, second_has_return_value = $build second_child, first_end_input, *cleanup_first
            $merge_labels i64(2) if first_has_return_value and second_has_return_value
            _has_return_value = first_has_return_value or second_has_return_value
            $free_local_value first_child
            $free_local_value second_child
            br *_successful

          *cleanup_first:
            $pop if first_has_return_value
            $free_local_value first_child
            br *_failed
        '

        cleanup_first_block = builder.create_block "sequence_cleanup_first"
        successful_block = builder.create_block "sequence_successful"

        first_end_input, first_has_return_value = @data[:first_child].build builder, start_input, modes, failed_block
        second_end_input, second_has_return_value = @data[:second_child].build builder, first_end_input, modes, cleanup_first_block
        builder.call builder.output_functions[:merge_labels], LLVM::Int64.from_i(2) if first_has_return_value and second_has_return_value
        @data[:first_child].free_local_value builder
        @data[:second_child].free_local_value builder
        builder.br successful_block

        builder.position_at_end cleanup_first_block
        builder.call builder.output_functions[:pop] if first_has_return_value
        @data[:first_child].free_local_value builder
        builder.br failed_block

        builder.position_at_end successful_block
        return second_end_input, first_has_return_value || second_has_return_value
      end
    end
    
    class Choice < ParsingExpression
      leftmost_leaves :first_child, :second_child

      def self.new(data)
        return super if data[:nested_choice]

        choice = super data
        leftmost_leaf = choice.get_leftmost_leaf
        if leftmost_leaf
          label_name = leftmost_leaf.object_id.to_s
          local_value = LocalValue.new name: label_name
          choice.replace_leftmost_leaf local_value
          local_label = Label.new child: leftmost_leaf, is_local: true, name: label_name
          return Sequence.new first_child: local_label, second_child: choice
        end

        return choice
      end

      def build(builder, start_input, modes, failed_block)
        first_child_block = builder.insert_block
        second_child_block = builder.create_block "choice_second_child"
        successful_block = builder.create_block "choice_successful"

        builder.position_at_end first_child_block
        first_end_input, first_has_return_value = @data[:first_child].build builder, start_input, modes, second_child_block
        first_child_exit_block = builder.insert_block

        builder.position_at_end second_child_block
        second_end_input, second_has_return_value = @data[:second_child].build builder, start_input, modes, failed_block
        second_child_exit_block = builder.insert_block

        builder.position_at_end first_child_exit_block
        builder.call builder.output_functions[:push_empty] if not first_has_return_value and second_has_return_value
        builder.br successful_block
        
        builder.position_at_end second_child_exit_block
        builder.call builder.output_functions[:push_empty] if not second_has_return_value and first_has_return_value
        builder.br successful_block
        
        builder.position_at_end successful_block
        end_input = builder.phi LLVM_STRING, first_child_exit_block => first_end_input, second_child_exit_block => second_end_input
        return end_input, first_has_return_value || second_has_return_value
      end
    end
    
    class Repetition < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        first_failed_block = builder.create_block "repetition_first_failed"
        loop_block = builder.create_block "repetition_loop"
        break_block = builder.create_block "repetition_break"
        exit_block = builder.create_block "repetition_exit"
        
        child_end_input, has_return_value = @data[:child].build builder, start_input, modes, @data[:at_least_once] ? failed_block : first_failed_block
        first_block = builder.insert_block
        builder.call builder.output_functions[:push_array], LLVM::TRUE if has_return_value
        builder.br loop_block
        
        builder.position_at_end loop_block
        loop_input_phi = builder.phi LLVM_STRING, first_block => child_end_input
        input = loop_input_phi
        
        input, glue_has_return_value = @data[:glue_expression].build builder, input, modes, break_block if @data[:glue_expression]
        builder.call builder.output_functions[:pop] if glue_has_return_value

        child_end_input, _ = @data[:child].build builder, input, modes, break_block
        loop_input_phi.add_incoming builder.insert_block => child_end_input
        builder.call builder.output_functions[:append_to_array] if has_return_value
        builder.br loop_block
        
        builder.position_at_end first_failed_block
        builder.call builder.output_functions[:push_array], LLVM::FALSE if has_return_value
        builder.br exit_block

        builder.position_at_end break_block
        builder.br exit_block

        builder.position_at_end exit_block
        end_input = builder.phi LLVM_STRING, first_failed_block => start_input, break_block => loop_input_phi
        return end_input, has_return_value
      end
    end

    class Until < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        entry_block = builder.insert_block
        loop1_block = builder.create_block "until_loop1"
        loop2_block = builder.create_block "until_loop2"
        exit_block = builder.create_block "until_exit"
        
        builder.position_at_end loop1_block
        input_phi = builder.phi LLVM_STRING, entry_block => start_input
        until_end_input, until_has_return_value = @data[:until_expression].build builder, input_phi, modes, loop2_block
        builder.call builder.output_functions[:append_to_array] if until_has_return_value
        builder.br exit_block
        
        builder.position_at_end loop2_block
        child_end_input, child_has_return_value = @data[:child].build builder, input_phi, modes, failed_block
        input_phi.add_incoming builder.insert_block => child_end_input
        builder.call builder.output_functions[:append_to_array] if child_has_return_value
        builder.br loop1_block

        builder.position_at_end entry_block
        builder.call builder.output_functions[:push_array], LLVM::FALSE if until_has_return_value or child_has_return_value
        builder.br loop1_block

        builder.position_at_end exit_block
        return until_end_input, until_has_return_value || child_has_return_value
      end
    end
    
    class PositiveLookahead < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        _, has_return_value = @data[:child].build builder, start_input, modes, failed_block
        builder.call builder.output_functions[:pop] if has_return_value
        return start_input, false
      end
    end
    
    class NegativeLookahead < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        lookahead_failed_block = builder.create_block "lookahead_failed"
  
        _, has_return_value = @data[:child].build builder, start_input, modes, lookahead_failed_block
        builder.call builder.output_functions[:pop] if has_return_value
        builder.br failed_block
        
        builder.position_at_end lookahead_failed_block
        return start_input, false
      end
    end
    
    class RuleCall < ParsingExpression
      leftmost_leaves :self

      def arguments
        @data[:arguments] || []
      end
      
      def referenced
        @referenced ||= begin
          referenced = parser[@data[:name].to_sym]
          raise CompilationError.new("Undefined rule \"#{@data[:name]}\".", rule) if referenced.nil?
          raise CompilationError.new("Wrong argument count for rule \"#{@data[:name]}\".", rule) if referenced.parameters.size != arguments.size
          referenced
        end
      end
      
      def build(builder, start_input, modes, failed_block)
        direct_left_recursion_block = builder.create_block "direct_left_recursion"
        no_direct_left_recursion_block = builder.create_block "no_direct_left_recursion"
        successful_block = builder.create_block "rule_call_successful"

        is_direct_recursion = (referenced == rule ? LLVM::TRUE : LLVM::FALSE)
        is_left_recursion = builder.icmp :eq, start_input, builder.rule_start_input, "is_left_recursion"
        is_direct_left_recursion = builder.and is_direct_recursion, is_left_recursion, "is_direct_left_recursion"
        builder.cond is_direct_left_recursion, direct_left_recursion_block, no_direct_left_recursion_block
        
        builder.position_at_end direct_left_recursion_block
        builder.store LLVM::TRUE, builder.direct_left_recursion_occurred
        in_recursion_loop = builder.icmp :ne, builder.left_recursion_previous_end_input, LLVM_STRING.null, "in_recursion_loop"
        in_recursion_loop_block = builder.create_block "in_recursion_loop"
        builder.cond in_recursion_loop, in_recursion_loop_block, failed_block

        builder.position_at_end in_recursion_loop_block
        builder.call builder.output_functions[:locals_load], LLVM::Int64.from_i(get_local_label("<left_recursion_value>", 0)) if referenced.rule_has_return_value?
        builder.br successful_block
        
        builder.position_at_end no_direct_left_recursion_block
        arguments.each { |arg| arg.build builder, start_input, modes, failed_block }
        arguments.size.times { builder.call builder.output_functions[:locals_push] }
        call_end_input = builder.call referenced.internal_match_function(builder.traced), start_input, modes, *builder.output_functions.values
        arguments.size.times { builder.call builder.output_functions[:locals_pop] }
        
        rule_successful = builder.icmp :ne, call_end_input, LLVM_STRING.null, "rule_successful"
        builder.cond rule_successful, successful_block, failed_block
        
        builder.position_at_end successful_block
        end_input = builder.phi LLVM_STRING, in_recursion_loop_block => builder.left_recursion_previous_end_input, no_direct_left_recursion_block => call_end_input
        return end_input, referenced.rule_has_return_value?
      end
    end
    
    class ParenthesizedExpression < ParsingExpression
      leftmost_leaves :child

      def build(builder, start_input, modes, failed_block)
        return @data[:child].build builder, start_input, modes, failed_block
      end
    end
  end
end