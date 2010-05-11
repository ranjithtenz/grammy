
module Grammy
	module Rules

		MAX_REPETITIONS = 10_000

		# Special operators used in the Grammar DSL.
		# The module is designed to be removable so the extra operators
		# wont pollute String, Symbol and Range.
		module Operators

			# includes the module so that it can be removed later with #exclude
			def self.included(target)
				# create a clone of the module so the methods can be removed from the
				# clone without affecting the original module
				cloned_mod = self.clone
				my_mod_name = name

				# store the module clone that is included
				target.class_eval {
					@@removable_modules ||= {}
					@@removable_modules[my_mod_name] = cloned_mod
				}

				# make backup of already defined methods
				cloned_mod.instance_methods.each {|imeth|
					if target.instance_methods.include? imeth
						target.send(:alias_method,"__#{imeth}_backup",imeth)
					end
				}

				cloned_mod.send(:append_features,target)
			end

			# removes the module from the target by
			# removing added methods and aliasing the backup
			# methods with their original name
			def self.exclude(target)
				# get the module
				mod = target.send(:class_eval){
					@@removable_modules
				}[name] || raise("module '#{name}' not found in internal hash, cant exclude it")

				# remove / restore the methods
				mod.instance_methods.each {|imeth|
					mod.send(:undef_method,imeth)

					if target.instance_methods.include? "__#{imeth}_backup"
						target.send(:alias_method,imeth,"__#{imeth}_backup")
						target.send(:undef_method,"__#{imeth}_backup")
					end
				}
			end

			def &(right)
				right = Rule.to_rule(right)
				right.backtracking = false
				Sequence.new(nil,[self,right], helper: true)
			end

			def >>(other)
				Sequence.new(nil,[self,other], helper: true)
			end

			def |(other)
				Alternatives.new(nil,[self,other], helper: true)
			end

			def *(times)
				times = times..times if times.is_a? Integer
				raise("times must be a range or int but was: '#{times}'") unless times.is_a? Range

				Repetition.new(nil,Rule.to_rule(self),times: times, helper: true)
			end

			def +@
				Repetition.new(nil,self,times: 1..MAX_REPETITIONS, helper: true)
			end

			def ~@
				Repetition.new(nil,self,times: 0..MAX_REPETITIONS, helper: true)
			end
		end

		#
		# RULE
		#
		class Rule
			include Operators

			attr_accessor :name, :parent
			attr_reader :grammar, :options, :debug, :type
			attr_writer :helper, :backtracking, :skipping, :ignored

			def initialize(name,options={})
				setup(name,options)
			end

			def setup(name,options={})
				@name = name
				@helper = options.delete(:helper) || !name
				@callbacks = options.extract!(:modify_ast,:on_error,:on_match)

				options = options.with_default(backtracking: true, skipping: false, ignored: false, debug: :like_root, type: :anonymous)
				@backtracking = options.delete(:backtracking)
				@skipping = options.delete(:skipping)
				@ignored = options.delete(:ignored)
				@debug = options.delete(:debug)
				@type = options.delete(:type)
				@options = options
			end

			def root
				cur_rule = self
				while cur_rule.parent
					cur_rule = cur_rule.parent
				end

				cur_rule
			end

			def debugging?
				raise "invalid debug mode: #{@debug.inspect}" unless [:like_root,:all,:root_only,:none].include? @debug
				
				if root.debug == :all
					true
				elsif root.debug == :root_only
					root == self
				else
					false
				end
			end

			def type
				result = @type || root.type
				raise unless [:anonymous,:rule,:token,:fragment,:skipper].include? result
				result
			end

			# For debugging purposes: returns the classname
			def class_name
				self.class.name.split('::').last
			end

			## true iff this rule is a helper rule. a rule is automatically a helper rule when it has no name.
			## a helper rule generates no AST::Node
			#def helper?
			#	raise unless [true,false].include? @helper
			#	@helper
			#end

			# TRUE iff the node generated by this rule should be mergeable with nodes of the same type.
			# Used to store token text in one node.
			def merging_nodes?
				raise unless [true,false].include? @helper
				@helper
			end

			# TRUE iff a node should be generated when this rule matches.
			def generating_node?
				raise unless [true,false].include? @helper
				@helper
			end

			def backtracking?
				raise unless [true,false].include? @backtracking
				@backtracking != false
			end

			def skipping?
				grammar.skipper and (@skipping or (root.skipping? unless root==self))
			end

			def generating_ast?
				raise unless [true,false].include? @ignored
				@ignored
			end

			# true when the matched string should not be part of the generated AST (like ',' or '(')
			def ignored?
				raise unless [true,false].include? @ignored
				@ignored
			end

			def children
				raise NotImplementedError
			end

			def grammar=(gr)
				raise unless gr.is_a? Grammar
				@grammar = gr
				children.each{|child|
					child.grammar= gr if child.kind_of? Rule
				}
			end

			def create_ast_node(context,range,children=[])
				node = AST::Node.new(name, merge: merging_nodes?, range: range, stream: context.stream, children: children)
				modify_node(node)
			end

			# apply callback to node
			def modify_node(node)
				if @callbacks[:modify_ast]
					node = @callbacks[:modify_ast].call(node)
				end
				node
			end

			def skip(context)
				grammar.skipper.match(context)
			end

			def match(context)
				raise NotImplementedError
			end

			def self.to_rule(input)
				case input
				when Range then RangeRule.new(nil,input,helper: true)
				when Array then Alternatives.new(nil,input, helper: true)
				when Symbol then RuleWrapper.new(input,helper: true)
				when String then StringRule.new(input,helper: true)
				when Integer then StringRule.new(input.to_s,helper: true)
				when Rule then input
				else
					raise "invalid input '#{input}', cant convert to a rule"
				end
			end

			def to_s
				class_name + '{' + children.join(',') + '}'
			end

			def to_image(name)
				raise NotImplementedError
				require 'graphviz'
				graph = GraphViz.new(name)
				graph.node[shape: :box, fontsize: 8]

				to_image_impl(graph)
			end

			def rule_class_name_abbreviation
				case class_name
					when "RuleWrapper" then "Wrp"
					else class_name[0,3]
				end
			end

			def debug_scope_name
				abbr = rule_class_name_abbreviation

				scope_name = name || ':'+abbr
				#scope_name = '>' if self.class == RuleWrapper
				scope_name
			end

			def debug_start(context)
				Log4r::NDC.push(debug_scope_name) if self.class != RuleWrapper
				#start = context.position
				#grammar.logger.debug("match(#{context.stream[start,15].inspect},#{start})") if debugging?
			end

			def debug_end(context,match)
				consumed = context.stream[match.start_pos,match.length]
				range = match.start_pos..match.end_pos

				result = match.success? ? "SUCC" : "FAIL"
				grammar.logger.debug("\t\t #{result}[#{range}]: #{consumed.inspect}") if debugging?
				Log4r::NDC.pop if self.class != RuleWrapper
			end
		end

		#
		# LeafRule
		# - just a helper class
		class LeafRule < Rule
			def children
				[]
			end

			#def debug_start(context)
			#	Log4r::NDC.push(debug_scope_name)
			#end

			#def debug_end(context,match)
			#	data = match.ast_node.data if match.ast_node
			#	result = match.success? ? "SUCCESS" : "FAIL"
			#	grammar.logger.debug("# #{result} => #{data.inspect},#{match.start_pos}..#{match.end_pos}") if debugging?
			#	Log4r::NDC.pop
			#end
		end

	end # Rules
end # Grammy