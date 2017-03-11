# coding: utf-8
require "../named_tuple_extensions"
require "./exceptions/*"
require "./parse_stack"
require "./environment"

alias Production = {id: Int32, lhs: Symbol, rhs: Array(String)}
alias ActionNotReduce = {id: Int32, type: Symbol}
alias Reduce = {id: Int32, type: Symbol, production: Production}
alias Action = ActionNotReduce | Reduce

module CLTK
  private def self.build_parse_opts(opts : NamedTuple)
    {
      accept:     :first,
      parse_tree: nil,
      verbose:    nil,
    }.merge(opts).merge(
      {env: opts.fetch(:env, nil) || Environment.new}
    )
  end

  def self.parse_with_parser(parser, tokens, options = NamedTuple.new)
    unless parser
      raise "no parser given"
    end
    opts = build_parse_opts(options)

    # Stack IDs to keep track of them during parsing.
    stack_id = 1
    # Error mode indicators.
    error_mode      = false
    reduction_guard = false

    # Our various list of stacks.
    accepted   = [] of Parser::ParseStack
    moving_on  = [] of Parser::ParseStack
    processing = [Parser::ParseStack.new(stack_id)]
    env = opts.fetch(:env, nil).as(Environment)

    tokens.each_with_index do |token, index|

      unless parser[:symbols].includes?(token.type)
        raise "invalid token"
      end

      while (processing.any?)
        stack = processing.shift

        # Execute any token hooks in this stack's environment.
        parser[:token_hooks].fetch(
          token.type, [] of Proc(Environment, Nil)
        ).each { |hook| hook.call(env) }

        # Get the available actions for
        # this to_h is necessary because crystal 0.21 crashes
        # on programmatical acces to the key via ..[:actions][token.type]
        actions = parser[:states][stack.state][:actions].to_h[token.type.as(Symbol)]
        if actions.empty?
          next
        end

        # Make (stack, action) pairs, duplicating the
	# stack as necessary.
        pairs = actions.map_with_index do |action, index|
          {index == 0 ? stack : stack.branch(stack_id += 1), action}.as({Parser::ParseStack, Action})
        end

        pairs.each do |pair|
          stack, action = pair
          case action[:type]
          when :ACCEPT
            if opts[:accept] == :all
	      accepted << stack
            else
              return stack.result
            end
          when :REDUCE
            production_proc, pop_size = parser[:procs][action[:id]]
            if !production_proc
	      raise InternalParserException.new "No production #{action[:id]} found."
	    end
            args, positions = stack.pop(pop_size)
	    env.set_positions(positions)

            if !production_proc[:selections].empty?
              args = production_proc[:selections].map do |selection|
                args[selection].as(Type)
              end.to_a
            end
	    result = production_proc[:proc].call(
              args.as(Type), env, production_proc[:arg_type]
            )
            actions = parser[:states][stack.state][:actions]
            symbol = parser[:lh_sides][action[:id]]

	    if (goto = parser[:states][stack.state][:actions].to_h[parser[:lh_sides][action[:id]]][0]?)
              pos0 = nil
              if args.empty?
                pos0 = stack.position
                pos0.stream_offset += pos0.length + 1
                pos0.line_offset += pos0.length + 1
                pos0.length = 0
              else
                pos0 = env.pos( 0).as(StreamPosition)
		pos1 = env.pos(-1).as(StreamPosition)
		pos0.length = (pos1.stream_offset + pos1.length) -
                              pos0.stream_offset
              end
              result = nil if result.is_a? Void
	      stack.push(goto[:id], result, parser[:lh_sides][action[:id]], pos0)
            else
              raise InternalParserException.new "No GoTo action found in state #{stack.state} after reducing by production #{action[:id]}"
            end
	    processing << stack

          when :SHIFT
	    stack.push(action[:id], token.value, token.type, token.position)
            # This stack is ready for the next
	    # token.
	    moving_on << stack

	    # Exit error mode.
	    # error_mode = false
          end
        end
      end

      processing = moving_on
      moving_on  = [] of Parser::ParseStack

      # If we don't have any active stacks at this point the
      # string isn't in the language.
      if opts[:accept] == :first && processing.size == 0
        {% if env("VERBOSE") %}
          v.close unless v == STDOUT
        {% end%}
        pp processing
	raise NotInLanguage.new(tokens[0...index], tokens[index], tokens[index+1..-1])
      end
      reduction_guard = false
    end

    results = accepted.map { |stack| stack.result.as(CLTK::Type) }

    if (env).he
      raise HandledError.new(env.errors, results.as(CLTK::Type))
    else
      return results
    end

  end
end
