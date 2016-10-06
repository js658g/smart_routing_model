#-----------------------------------------
#-----------------------------------------
#-----------------------------------------
#
# First Data Smart Routing ROI Model
# Created by Thomas Rawley
#
# Version History
# ---------------
# 1.0 - 2013-05-07 initial release
# 1.1 - 2013-05-13 added ability to have a network priority for billing and one for routing, which may be different
# 1.2 - 2013-05-16 enhanced the parse_csv funtion to better handle errors with blank values & carved out the calculate_orders so it can be run independently of process_transactions
# 1.3 - 2013-05-20 added in the premier networks as their own unique networks which will allow for the removal of the premier indicator in the rate file 
# 1.4 - 2013-05-21 removed premier indicator from rates and added in networks bid functionality so a transaction now has a low_bid_network and low_bid_fee 
# 1.5 - 2013-06-17 adding the feature for the user to give multiple amount ranges for calculating orders and adding mcc column to order_range_details file
# 1.6 - 2013-06-18 added output file to support heat map of original vs routing (based on orders provided) network 
# 1.7 - 2013-06-25 added logic to swtich the original network to PAVD from INTERLINK if INTERLINK is not routable but PAVD is
# 1.8 - 2013-07-03 added functionality to determine high cost fee and high cost network for each transaction then display that in the output report to support potential revenue sharing sales model
# 1.9 - 2013-11-01 added functionality for interlink/pavd business (this is indicated by the premier indicator on the interlink/pavd network). changes are also made to networks.yml and the rate file.
# 1.10 - 2014-09-15 - added functionality to allow Accel Assurance premier network to be properly identified. This is the first time a network has more than 1 premier partner so it is being accounted for with special asset indicators
# 1.11 - 2015-02-27 - added pin less functionality to the existing pin model.
# © Copyright First Data 2015
#-----------------------------------------
#-----------------------------------------
#-----------------------------------------


require 'yaml'				#so we can import/export our YAML config files
require 'csv'				#so we can read and write data to CSV files
require 'win32console'		#pre-req for colored
require 'colored'			#allows us to print in color on the command line
require 'progressbar'		#so we can let the user know the status and time remaining while running the model
require 'highline/import'   #so we can ask questions on the command line
require 'net/https'			#so we can log into an https site (using mechanize below...and for getting into messageway to download the pin debit bin files)
require 'mechanize'			#libraries for a ruby browser - used to get the pin debit bin files from messageway
require 'fileutils'			#mostly so we can use mkdir_p
require 'digest/md5'		#needed because OCRA will fail when downloading the BIN files without explicitly including it

class SmartRoutingModel
	attr_reader :rate_tree, :profile, :networks
	
	def self.version
		"1.11"
	end

	
	def initialize
		@client_output_dir = './'
		@networks = YAML.load_file('./inputs/config/networks.yml')
		@options = YAML.load_file('./inputs/config/options.yml')

		set_reset_instance_variables
		
		@bin_tree = Hash.new
		@rate_tree = Hash.new
		
		@assets = {	'V' => '001', 
					'U' => '000', 
					'T' => '111', 
					'S' => '101', 
					'R' => '110', 
					'Q' => '100', 
					'A' => '000', 
					'B' => '000',
					'C' => '000',
					'D' => '000',
					'E' => '000',
					'F' => '110', 
					'G' => '110', 
					'H' => '110', 
					'I' => '110',
					'J' => '110',
					'K' => '110',
					'L' => '100',
					'M' => '001',
					'N' => '000',
					'P' => '001',
					'W' => '111',
					'X' => '101'
					} #regulated, fraud, premier - this data comes from the DBOR team (current contact is Rachel Lasca 2013-04-29)
					
					@pin_inds = {    
					'A' => '010', 
          'B' => '101', 
          'C' => '011', 
          'D' => '110', 
          'E' => '111',
          'L' => '001', 
          'P' => '100',                                                                                          
          } #pin, pos-pinless, billpay pinless

						#DRD-BIN-ASSET-IND
						#------------------------------

						#V          Premier Issuer (Unregulated)         
						#U          Non-Premier Issuer (Unregulated)              
						#T          Regulated Premier Issuer with Fraud-prevention adjustment            
						#S          Regulated Premier Issuer without Fraud-prevention adjustment       
						#R          Regulated Non-Premier Issuer with Fraud-prevention adjustment     
						#Q          Regulated Non-Premier Issuer without Fraud-prevention adjustment

						#A          Non-Premier Issuer (Unregulated)              
						#B          Non-Premier Issuer (Unregulated)                   
						#C          Non-Premier Issuer (Unregulated)
						#D          Non-Premier Issuer (Unregulated)
						#E          Non-Premier Issuer (Unregulated)

						#F          Regulated Non-Premier Issuer with Fraud-prevention adjustment
						#G          Regulated Non-Premier Issuer with Fraud-prevention adjustment
						#H          Regulated Non-Premier Issuer with Fraud-prevention adjustment
						#I          Regulated Non-Premier Issuer with Fraud-prevention adjustment
						#J          Regulated Non-Premier Issuer with Fraud-prevention adjustment
						#K          Regulated Non-Premier Issuer with Fraud-prevention adjustment
						#L          Regulated Non-Premier Issuer without Fraud-prevention adjustment
						#M          Premier Issuer (Unregulated)     
						#N          Non-Premier Issuer (Unregulated)        

						#P          Pulse Pay Choice Unregulated / Accel Assurance Unreg
						#W          Pulse Pay Choice Regulated with Fraud
						#X          Pulse Pay Choice Regulated without Fraud 
 

            #PINLESS IND        DESCRIPTION
            #-------------------------------
            #A         POS-Pinless
            #B         Pinned and Billpay-Pinless
            #C         Billpay-Pinless / POS-PinLess
            #D         Pinned / POS-Pinless
            #E         Pinned/Billpay/POS-Pinless
            #L         billpay-Pinless only
            #P         Pinned only

						

	end
	
	def load_profile
		@profile.clear unless @profile.nil?
		@profile = YAML.load_file(@client_dir + 'profile.yml')
		@excluded_networks = @profile['network_exclusion']
		@priority_networks = @profile['network_billing_priority']
		@priority_routing_networks = @profile['network_routing_priority']
		@networks.clear unless @networks.nil?
		@networks = YAML.load_file('./inputs/config/networks.yml')
		@networks.each { |key, value| value.merge! @profile['details'][key] unless @profile['details'][key].nil? }

		@networks.each do |network, values|
			values['interchange'] = values['interchange'].to_s + 'I' unless values['interchange'].to_s == 'null' || values['rateable_network'].to_i == 0
			values['switch'] = values['switch'].to_s + 'S' unless values['switch'].to_s == 'null' || values['rateable_network'].to_i == 0
		end
	end
	
	
	def get_client_folder
		client_dirs = Dir.entries('./clients').select {|entry| File.directory? File.join('./clients',entry) and !(entry =='.' || entry == '..') }
		client_dirs.sort!
		
		CSV.open('./clients/folder_list.csv', 'wb') do |csv|
			csv << ['folder']
			client_dirs.sort.each do |dir|
				csv << [dir.to_s]
			end
		end
		
		print "*******************\n".green
		num = 1
		client_dirs.sort.each do |client| 
			print (num.to_s + ". " + client.to_s + "\n").green
			num += 1
		end
		print "*******************\n\n".green
		client_num = ask 'Which client is this model run for? '
		@client_dir = "./clients/#{client_dirs[client_num.to_i-1]}/"
		
		#get the output folder...or make it if it does not already exist
		@client_output_dir = @client_dir + @options['output_folder']
		FileUtils.mkdir_p(@client_output_dir) unless File.directory?(@client_output_dir)
	end
	
	#this needs to be called before you start processing transactions. it loads the rate and bin file from YAML
	def prepare_for_processing
		begin
			@rate_tree = YAML.load(File.read(@options['rate_tree_yaml'])) #if File.exist?(@options['rate_tree_yaml'])
		rescue
			raise "Error loading rate file.\nPlease ensure you load rates before processing transactions"
			
		end
		
		begin
			@bin_tree = YAML.load(File.read(@options['bin_tree_yaml']))  #if File.exist?(@options['bin_tree_yaml'])
		rescue
			raise "Error loading BIN file.\nPlease ensure you load the BINs before processing transactions"
		end
		
		get_client_folder #must come before load_profile
		load_profile
		set_reset_instance_variables
	end
	
	def set_reset_instance_variables
		@total_transactions = 0
		@unique_amounts_by_mcc = {}
		@int_pavd_switch = false #v1.7
		@pin_flag = 1

		
		@summary_chart_data = 	{ 
									1 => {'left' => {'label' => 'Transactions Sent','value' => 0}, 'mid' => {'label' => nil,'value' => 0}, 'right' => {'label' => nil,'value' => 0}},
									2 => {'left' => {'label' => 'PIN Debit','value' => 0}, 'mid' => {'label' => 'Not PIN Debit','value' => 0}, 'right' => {'label' => nil,'value' => 0}},
									3 => {'left' => {'label' => 'Rates Available','value' => 0}, 'mid' => {'label' => 'No Rates Available','value' => 0}, 'right' => {'label' => nil,'value' => 0}}
								}
								
		@network_summary = Hash.new
		@pinless_summary = Hash.new
		@fee_summary = Hash.new
		@network_differences = Hash.new
		@routing_summary = Hash.new
		@high_low_cost_diff = 0.0 #v1.8
		
		@orders = {} #for the lowest cost network priority orders
		@unique_network_orders = {'0' => {}, '1' => {}} #this will hold the unique network orders for unregulated (0) and regulated (1)
		@chunked_network_orders = {'0' => [], '1' => []} #this will hold the chunked network orders (low and high ranges instead of all the consecutive numbers
	end
	
	def load_bin_file(pin_debit_filename, gbf_filename)
	
		#used for testing purposes to hardcode the names
  	#	pin_debit_filename = 'GASX233A.11052014.040435.TXT'
	  #	gbf_filename = 'KXCV00P.GB.GLOBAL.BIN.RANGE.ALL.G1993V00.txt'

		
		@bin_tree.clear #in case the user reloads the bin file without first exiting the application
		bin_file = File.new(@options['pin_bin_file_folder'] + pin_debit_filename)
		
		#counter = 1
		while line = bin_file.gets
			if line[0,1] == 'B' #only want detail rows
				pan = line[1,2].to_i
				bin_len = line[3,2].to_i
				bin = line[5, bin_len.to_i].to_s
				network = line[31,2].to_i
				asset_ind = line[36,1]
				pinless = line[33,1]
				
			
				#this is the awesome part where we have to change the network to the premier version of the network if the bin is listed as premier
				#everything else would stay exactly the same...except of course needing to ensure that the rate file has the networks split out into premier and non premier
				network = @networks[network]['routable_id']
			
				#v1.10 - changed this if statement from      network = @networks[network]['premier_partner'] if get_attribute(asset_ind, 'premier') == '1'
				if get_attribute(asset_ind, 'premier') == '1'
					if asset_ind == 'P' && network.to_i == 2 #P means Accel Assurance Unreg (if the network is Accel and the asset indicator is P then that really means Accel Assurance)
						network = 3
					else #otherwise just grab the standard premier partner from networks.yml
						network = @networks[network]['premier_partner']
					end
				end
				
				next if @networks[network]['rateable_network'].to_i != 1 #we are only going to have rates for certain networks so only add networks which have rates
				
				@bin_tree.merge! pan => Hash.new unless @bin_tree[pan]
				@bin_tree[pan].merge! bin_len => Hash.new unless @bin_tree[pan][bin_len]
				@bin_tree[pan][bin_len].merge! bin => Hash.new unless @bin_tree[pan][bin_len][bin]
				@bin_tree[pan][bin_len][bin].merge!((network.to_i.to_s + asset_ind) =>  '0' + get_pin_indicator(pinless, 'pinless_pos')) { |key, v1, v2| merge_bin_values(v1, v2) }   #25V => 01  means network 25 with asset indicator V and 01 means prepaid and pinless
				
			end
		end
		bin_file.close
		
	
		#the global bin file (GBF) is used for 1 purpose only...to get the BINs which are considered prepaid. all other required attributes are in the pin debit bin file
		gbf_file = File.new(@options['gbf_bin_file_folder'] + gbf_filename)
    
  
    while line = gbf_file.gets
      if line[0,1] == 'D' && line[194,1] == 'P'  #only want detail rows and rows where prepaid is true

        pan = line[35,2].strip.to_i
        bin_len = line[33,2].strip.to_i
        bin_low = line[1,16][0..bin_len].strip.to_i
        bin_high = line[17,16][0..bin_len].strip.to_i


         #replace the 0 with a 1 to indicate prepaid if the bins match. GBF has a BIN range whereas PIN debit file has each bin individually so we have to loop through each bin in the range
        (bin_low..bin_high).each do |bin|

          begin
            @bin_tree[pan][bin_len][bin.to_s].each { |k,v| 
              prev_val =  @bin_tree[pan][bin_len][bin.to_s][k]
              i = prev_val[1,1]
              @bin_tree[pan][bin_len][bin.to_s][k] = '1'+i
              
            }
          rescue
              #do nothing
          end
        end
      end
    end
        
    gbf_file.close

		File.open(@options['bin_tree_yaml'], 'w') { |f| f.write(YAML.dump(@bin_tree)) }
		return
	end
	
	def merge_bin_values(v1, v2)
		#get 2nd character from v1 and v2. If either is a 1 then return 01 - the first character here will always be 0
		v1_second_char = v1[1,1]
		v2_second_char = v2[1,1]
		
		return_value = v1_second_char == '1' || v2_second_char == '1' ? '1' : '0'
		
		'0' + return_value
	end
	
	def load_rates(filename)
		@rate_tree.clear #in case the user reloads the bin file without first exiting the application
		CSV.foreach(@options['rates_folder'] + filename, :headers => true, :return_headers => false, :header_converters => :symbol) do |row|
		  
			network_id = row[:network_id].strip.to_i
	   	
			mccs = row[:mccs]
			mcc_low = row[:mcc_low].strip.to_i
			mcc_high = row[:mcc_high].strip.to_i
			pinless = row[:pinless].strip
			registered = row[:registered].strip
			regulated = row[:regulated].strip
			fraud = row[:fraud].strip
			prepaid = row[:prepaid].strip
			tier = row[:tier].strip
			pre_auth = row[:pre_auth].strip
			bid_fee = row[:bid_fee].strip
			bid_fee_bool = bid_fee == '1' ? true : false
			
			#pre auth works like this. if the mcc code of the transactions is "pre authable" as listed in the options YAML file
			#then we need to add in the pre-auth fee into the overall fee to determine lowest cost.
			
			fee_type = row[:fee_type].strip
			price_type =  row[:price_type].strip
			price_fixed =  row[:price_fixed].gsub('$', '').gsub(',', '').strip
			price_percent =  row[:price_percent].gsub('%', '').gsub(',', '').strip
			price_min =  row[:price_min].gsub('$', '').gsub(',', '').strip
			price_max =  row[:price_max].gsub('$', '').gsub(',', '').strip
			price_fraud =  row[:price_fraud].gsub('$', '').gsub(',', '').strip
			price_threshold_sign =  row[:price_threshold_sign].strip
			price_threshold =  row[:price_threshold].gsub('$', '').gsub(',', '').strip
			
			
			price_threshold = '0' if price_threshold == '-'
			price_fixed = '0' if price_fixed == '-'
			price_percent = '0' if price_percent == '-'
			price_min = '0' if price_min == '-'
			price_max = '0' if price_max == '-'
			price_fraud = '0' if price_fraud == '-'
			
			fee = Fee.new(
				:fee_type => fee_type,
				:price_type => price_type,
				:fixed => price_fixed.to_f,
				:percent => price_percent.to_f / 100.0,
				:min => price_min.to_f,
				:max => price_max.to_f,
				:fraud => price_fraud.to_f,
				:sign => price_threshold_sign,
				:threshold => price_threshold.to_f,
				:bid_fee => bid_fee_bool
			)
			
			@rate_tree.merge! network_id => Hash.new unless @rate_tree[network_id]
			
		
	   mccs.split(',').each do |mcc|
        mcc = mcc.strip
        

        ((mcc == 'range' ? (mcc_low..mcc_high) : []).to_a + [mcc]).each do |mcc| #this combines the range and regular MCC into 1 array and iterates
            mcc = mcc.to_s
        
          @rate_tree[network_id].merge! mcc => Hash.new unless @rate_tree[network_id][mcc]
    
          @rate_tree[network_id][mcc].merge! pinless => Hash.new unless @rate_tree[network_id][mcc][pinless]
          @rate_tree[network_id][mcc][pinless].merge! registered => Hash.new unless @rate_tree[network_id][mcc][pinless][registered]
          @rate_tree[network_id][mcc][pinless][registered].merge! regulated => Hash.new unless @rate_tree[network_id][mcc][pinless][registered][regulated]
          @rate_tree[network_id][mcc][pinless][registered][regulated].merge! fraud => Hash.new unless @rate_tree[network_id][mcc][pinless][registered][regulated][fraud]
          @rate_tree[network_id][mcc][pinless][registered][regulated][fraud].merge! prepaid => Hash.new unless @rate_tree[network_id][mcc][pinless][registered][regulated][fraud][prepaid]
          @rate_tree[network_id][mcc][pinless][registered][regulated][fraud][prepaid].merge! pre_auth => Hash.new unless @rate_tree[network_id][mcc][pinless][registered][regulated][fraud][prepaid][pre_auth]
          #this will allow multiple rates in the same lowest level node...which is required for threshold rates
          if @rate_tree[network_id][mcc][pinless][registered][regulated][fraud][prepaid][pre_auth][tier] #if the node already exists add a new fee to the array
            @rate_tree[network_id][mcc][pinless][registered][regulated][fraud][prepaid][pre_auth][tier] << fee
          else #is the node does not already exist create a new array
            @rate_tree[network_id][mcc][pinless][registered][regulated][fraud][prepaid][pre_auth].merge! tier => [fee] 
          end
        end
      end
  	end
  	
		File.open(@options['rate_tree_yaml'], 'w') { |f| f.write(YAML.dump(@rate_tree)) }
		return
	end
	
	def networks_for(t)
	
		#so we need to get a list of all the networks which the transaction can be routed to.
		#to do that we look at all the BIN lengths for the PAN associated with the transaction.
		#if we get the same network multiple times (at different BIN lengths) we need to take the asset indicator from the 
		#highest (longest) BIN length found. 
		#basically all the "attributes" of a transaction (regulated, fraud, premier, prepaid) need to come from the BIN entry
		#with the largest matching BIN length
		routable_networks = Hash.new
		begin
			@bin_tree[t.pan.to_i].keys.sort.reverse.each do |bin_len| #sort the bin lengths associated with the PAN...in descending order and iterate over them
			
        
				bins = @bin_tree[t.pan.to_i][bin_len] #grab the bins we are looking at in this iteration

				bin_lookup = t.ccn[0,bin_len] #determine the bin we are trying to find based on the CCN in the transaction
				#note: for some reason had to change the above line from bin_lookup = t.ccn[0,bin_len].to_i to the above. not sure why the bin_tree is now using strings instead of numbers
				#this may be something that needs to be fixed later
				
				if bins.key? bin_lookup.to_s #if there is a bin match
				  
					networks = bins.fetch bin_lookup #get the networks associated with the BIN

					networks.each do |network, value| #for each network add it to the routable networks unless the network is already there (added from a higher length bin)
						routable_networks.merge! network => value if routable_networks.select{|k,v| k.to_i == network.to_i}.empty? && !@excluded_networks.include?(network.to_i)
					end
				end
			end

		rescue
			#what to do? this transaction is not in the bin file...not sure we need to do anything really
		end

		#v1.11 - The following block addresses the pin and pinless logic
		t.networks_bef_deletion = routable_networks.clone
		
		t.pinless = '0'
		if transaction_was_originally_signature?(t) 
			if (t.amount <= 50)
				t.pinless = '1'
				routable_networks.delete_if {|key, value| value[1,1] == '0' && @networks[key.to_i]['sig'] == 0 }  #we need to delete the non pinless options because the transaction was originally signature and therefore the only options are signature and pinless			
				
				num_networks = 0
				network_is_sig = 0
				routable_networks.each do |key, value|
					network_is_sig = 1 if @networks[key.to_i]['sig'] == 1
					num_networks = num_networks + 1
				end
				
				t.pinless = '0' if num_networks == 1 && network_is_sig == 1
			else
				t.pinless = '0'
				routable_networks.delete_if {|key, value| @networks[key.to_i]['sig'] != 1}#if its greater than 50 then only sig should left in hash
			end
		end
		t.in_bin_file = routable_networks.empty? ? 0 : 1
		routable_networks
	end

	def transaction_was_originally_signature?(t)
		return true if @networks[t.original_network.to_i]['sig'].to_s == '1'
		return false
	end
	
	def lowest_cost_for(t)
		billable_network_fees = {}
		bid_network_fees = {}
		networks = networks_for t
		num_networks = networks.length

		
		networks.each do |key, value| #value will be the prepaid indicator here
        id = key.to_i
        asset_ind = key[-1..-1] #get last character from key
        registered = @networks[id]['registered']
        regulated = @assets[asset_ind][0,1]
        fraud = @assets[asset_ind][1,1]
        premier = @assets[asset_ind][2,1]
        prepaid = value[0,1]
        pinless = value[1,1]
        
        interchange_tier = @networks[id]['interchange']
        switch_tier = @networks[id]['switch']
        tiers = @networks[id]['interchange'] == 'null' ? 'null' : [interchange_tier, switch_tier] #if there are no interchange tiers then there are no switch tiers either...at least so far!
        
 
        mcc = @rate_tree[id].keys.include?(t.mcc) ? t.mcc : '*'
        pre_auth = t.pre_authable ? '1' : '0'
        
        #we need to change the original network to the premier partner if this is a premier transaction and we are looping over the partner network
        #this is really the only place to do it since we need to look at each network AND understand if that network should be treated as premier
        #v1.10 - changed this up to account for the Accel Assurance network - used to be this line: t.original_network = id if premier == '1' && @networks[t.original_network.to_i]['premier_partner'].to_i == id
        if premier == '1'
          if asset_ind == 'P' && (t.original_network.to_i == 2 || t.original_network.to_i == 4) # 2 = ACCEL, 4 = ACCEL ADVANTAGE
            t.original_network = 3
          else
            t.original_network = id if @networks[t.original_network.to_i]['premier_partner'].to_i == id
          end
        end
       
        fees = traverse(@rate_tree[id], [mcc, pinless, registered, regulated, fraud, prepaid, pre_auth, tiers]) #mcc, registered, regulated, fraud, prepaid, pre_auth, tiers
        fees.flatten! #calling here to only do it once...no need to do it every time in traverse
        fees.uniq! #might get the same fee twice. and doing it here instead of in traverse() for performance reasons...that would be a lot of calls to uniq 
   
		billable_fee = 0.0
        fees.each { |f| billable_fee += f.calculate(t, fraud, 'billable') }
        
        #to represent what is happening in production we only apply the bid if the transaction can be routed to multiple networks. if it can only be routed to 1 network then do NOT apply the bid.
        bid_fee = 0.0
        fees.each { |f| bid_fee += f.calculate(t, fraud, (num_networks == 1 ? 'billable' :'bid')) } 
        
        #we need to embed the prepaid indicator into the network name as well so we can parse it out later as needed
        helper = 'N'
        helper = 'Y' if prepaid.to_s == '1'
        
        pinless_ind = '0'
        pinless_ind = '1' if pinless.to_s == '1'
        
        billable_network_fees.merge! key + helper + pinless_ind => billable_fee  
        
        bid_network_fees.merge! key + helper + pinless_ind => bid_fee
    end

    #v1.8 - commented out the below low_cost variable assignment and replaced with the sorted_fees assignment
    #low_cost = billable_network_fees.to_a.sort do |x,y| 
    # #goal here is to determine if x is less than, equal to, or greater than y. (-1, 0, +1)
    # networkorig = t.original_network.to_i
    # networkx = x[0].to_i
    # networky = y[0].to_i
    # costx = x[1]
    # costy = y[1]
    #
    # #if the costs are the same drop to original network logic, else just base it on the value
    # order = costx <=> costy
    # order == 0 ? (networkx == networkorig ? -1 : (networky == networkorig ? +1 : 0)) : order
    #end.first #set the real lowest cost first by sorting the hash based on total fee and while respecting the original network...and then taking the first value which will be the lowest cost

    #so at this point we have all the fees for the network/asset combinations
    #now we need to determine the lowest cost one. if the original and another network are the same cost we need to ensure we take the original network. else take whichever one
    #v1.8 - added sorted_fees as an array so we can then pluck off the low_cost and the high_cost instead of doing the sort twice

	if @pin_flag == '1'
	if transaction_was_originally_signature?(t) 
		 billable_network_fees.each do |key, value|
		  if(key.to_i == t.original_network.to_i)
			billable_network_fees[key] = t.disc_amt unless t.disc_amt.nil?
		   end
		end
	end
	end

    
    if @pin_flag == '1'
    bid_network_fees.each do |key, value|
      if(key.to_i == t.original_network.to_i)
          bid_network_fees[key] = t.disc_amt unless t.disc_amt.nil?
      end
    end
end    

      sorted_fees = billable_network_fees.to_a.sort do |x,y| 
      #goal here is to determine if x is less than, equal to, or greater than y. (-1, 0, +1)
      networkorig = t.original_network.to_i
      networkx = x[0].to_i
      networky = y[0].to_i
      costx = x[1]
      costy = y[1]
    
      #if the costs are the same drop to original network logic, else just base it on the value
      order = costx <=> costy
      order == 0 ? (networkx == networkorig ? -1 : (networky == networkorig ? +1 : 0)) : order
    end #sort the hash based on total fee and while respecting the original network...and then taking the first value which will be the lowest cost
    
		low_cost = sorted_fees.first #the lowest cost will be the first item in the sorted hash
		high_cost = sorted_fees.last #the highest cost will be the last item in the sorted hash

		
		#so at this point we have all the fees for the network/asset combinations
		#now we need to determine the lowest cost one. if the original and another network are the same cost we need to ensure we take the original network. else take whichever one
		low_bid = bid_network_fees.to_a.sort do |x,y| 
			#goal here is to determine if x is less than, equal to, or greater than y. (-1, 0, +1)
			networkorig = t.original_network.to_i
			networkx = x[0].to_i
			networky = y[0].to_i
			costx = x[1]
			costy = y[1]
		
			#if the costs are the same drop to original network logic, else just base it on the value
			order = costx <=> costy
			order == 0 ? (networkx == networkorig ? -1 : (networky == networkorig ? +1 : 0)) : order
		end.first #set the low bid cost by sorting the hash based on total fee and while respecting the original network...and then taking the first value which will be the lowest cost
		
			#this part will handle the network priority list provided in the profile
		@priority_networks.each do |priority_id| #loop over each priority network...if none this will just loop 0 times
				priority_network = billable_network_fees.select{ |k,v| k.to_i == priority_id }.to_a.flatten #determine if the network fees contain the priority network we are iterating over

				unless priority_network.empty? #meaning if we found the priority network do something, else move on
					low_cost = priority_network
					break  #break out of loop...we don't care about any lower priority networks since we found this higher priority one
				end
		end
		
		unless low_cost.nil?
			t.low_cost_network = low_cost[0]
			t.low_cost_fee = low_cost[1]
			pinless_temp_indicator = t.low_cost_network[-3,3]
			asset = pinless_temp_indicator[0,1]
			pinless_indicator = pinless_temp_indicator[1,1]
			prepaid = '0'
			prepaid = '1' if low_cost[0][-1..-1] == 'Y'
			

			begin
				t.regulated = get_attribute(asset, 'regulated')
				t.fraud = get_attribute(asset, 'fraud')
				t.premier = get_attribute(asset, 'premier')
			rescue
				t.regulated = 0
				t.fraud = 0
				t.premier = 0				
			end
			
			t.prepaid = prepaid

		end

		#v1.8 - added the unless statment below
		unless high_cost.nil?
			t.high_cost_network = high_cost[0]
			t.high_cost_fee = high_cost[1]
		end
		
		unless low_bid.nil?
			t.low_bid_network = low_bid[0]
			t.low_bid_fee = low_bid[1]
		end
		
		
		#code changes for v1.7 (among a couple other 1 line locations)
		#this logic change accounts for the following scenario
		#	-original network was listed as INTERLINK
		#	-INTERLINK is not routable in the BIN file
		#	-PAVD is routable in the BIN file
		#	-therefore change the original network to PAVD
		#this accounts for the issue where BAMS and Buypass (among others I am sure) cannot distinguish between INTERLINK and PAVD and they list everything as INTERLINK.
		#the logic will NOT work in the reverse way (PAVD was original and swtich it to INTERLINK)
		
		if @int_pavd_switch && t.original_network.to_i == 25 #INTERLINK
			network_ids = billable_network_fees.keys.map { |network| network.to_i }
			original_network_routable = network_ids.include?(t.original_network.to_i) ? true : false
			alternate_network_routable = network_ids.include?(20) ? true : false
			t.original_network = '20' if !original_network_routable && alternate_network_routable
		end

		#changes for v1.9
		if @int_pavd_switch && t.original_network.to_i == 56 #INTERLINK BUSINESS
			network_ids = billable_network_fees.keys.map { |network| network.to_i }
			original_network_routable = network_ids.include?(t.original_network.to_i) ? true : false
			alternate_network_routable = network_ids.include?(58) ? true : false
			t.original_network = '58' if !original_network_routable && alternate_network_routable
		end
		#end changes for v1.9
		
		#end code changes for v1.7
		
		orig_fee = nil
		billable_network_fees.each do |k,v| #set original fee...if same network with different asset indicators always choose the lowest cost so we don't overstate any savings
			if t.original_network.to_i == k.to_i
				orig_fee = v if orig_fee.nil? || v < orig_fee
				
			else
				orig_fee = t.disc_amt
			end
		end
		t.original_fee = orig_fee
		t.billable_network_fees = billable_network_fees
		t.bid_network_fees = bid_network_fees
		set_routable_network_on t unless @priority_routing_networks.nil?
	end
	
	#the goal here is to loop through all the network fees and determine the routing network based on the profile network_routing_priority section
	def set_routable_network_on(t)
		routing_priority = @priority_routing_networks[t.regulated.to_i] #get the correct section to use (regulated or unregulated)
		
		return if routing_priority.nil? #nothing we can do here so just return

		#loop through each priority line item and determine the transaction amount falls in the range.
		#if so look at each priority network in order and see if we have a fee for it (meaning its a routable network)
		#if we find one set the routable network attributes on the transaction and return
		#otherwise keep looping
		routing_priority.each do |row|
			if t.amount >= row['low'] && t.amount <= row['high'] #if true then we now have the correct orders to use

				row['order'].each do |network_id|
					routing_network, routing_network_fee = t.billable_network_fees.select { |k,v| k.to_i == network_id.to_i }.to_a.flatten

					unless routing_network.nil?
						t.routing_network = routing_network
						t.routing_network_fee = routing_network_fee
						return
					end
				end
				
			end
		end		
	end
	
	def traverse(tree, values)
	
		return tree if values.empty? #base case - lowest level is an array of fees
	
		#copy the values array to a new local copy...otherwise we will be passing the same array around...each recurse call needs its "own" copy to work with
		new_values = values.dup
		value = new_values.shift
		fees = []
		[value].flatten.each do |v| #this loop is needed to account for the tier level as there are 2 tiers (interchange and switch)
			fees << traverse(tree[v], new_values) unless tree.nil? || tree[v].nil?
			fees << traverse(tree['null'], new_values) unless v == 'null' || tree.nil? || tree['null'].nil?
		end 
		fees
	end
	
	def process_transactions
		
		prepare_for_processing #prepare the model to process transactions
		@pin_flag = ask "Is this for a pin or pinless? (0 for pin, 1 for pinless)?"
		infile = ask "\n\nProvide transactions CSV filename (respective to client folder): "
		run_orders = 'Y'#ask "\nCalculate orders as well (Y/N)? "
		int_pavd_switch_local = ask "\nReplace INTERLINK with PAVD when INTERLINK is not routable but PAVD is (Y/N)? "  #v1.7
		int_pavd_switch_local = 'Y'
		
		
		@int_pavd_switch = int_pavd_switch_local == 'Y' ? true : false  #v1.7
		pp @pin_flag
		first_line = File.open(@client_dir + infile).first
		if @pin_flag == '0'
			if first_line.strip != 'ccn,pan,amount,mcc,original_network' #this is our required input format...if not this then we need to exit
				puts "File format is not valid. Cannot proceed".red
				return
			end
			else
			if first_line.strip != 'ccn,pan,amount,mcc,original_network,int_rate,disc_amt' #this is our required input format...if not this then we need to exit
				puts "File format is not valid. Cannot proceed".red
				return
			end	
		end
		
		print "\n\nCounting rows in #{infile}\n\n".green
		
		@total_transactions = -1 + File.foreach(@client_dir + infile).inject(0) {|c, line| c+1} #count # of lines in the csv file and remove the header row
		update_summary_chart_data 1, 'left', @total_transactions
		
		print "Commencing modeling excerise on #{@total_transactions} transactions\n\n".green
		pbar = ProgressBar.new("Model", @total_transactions)
		pbar.bar_mark = '='

		CSV.open(@client_output_dir + 'detail.csv', 'wb') do |csv|
			csv <<  Transaction.headers #write header rows
			
			CSV.foreach(@client_dir + infile, :headers => true, :return_headers => false, :header_converters => :symbol) do |row|
			  
				mcc = row[:mcc].strip
				pre_authable = @options['pre_auth_mccs'].include?(mcc.to_i) ? true : false 			
				
				#v1.11 - modifications for pin/pinless model
				if @pin_flag == '0'
					t = Transaction.new(:ccn => row[:ccn].strip, :pan => row[:pan].strip, :mcc => mcc, :amount => row[:amount].strip.to_f, :original_network => row[:original_network].strip, :pre_authable => pre_authable)
				else
					t = Transaction.new(:ccn => row[:ccn].strip, :pan => row[:pan].strip, :mcc => mcc, :amount => row[:amount].strip.to_f, :original_network => row[:original_network].strip, :int_rate => row[:int_rate].strip, :disc_amt => row[:disc_amt].strip.to_f, :pre_authable => pre_authable)
				end
			#t = Transaction.new(:ccn => row[:ccn].strip, :pan => row[:pan].strip, :mcc => mcc, :amount => row[:amount].strip.to_f, :original_network => row[:original_network].strip, :int_rate => row[:int_rate].strip, :disc_amt => row[:disc_amt].strip.to_f, :pre_authable => pre_authable)
				t.pinless = 0
				lowest_cost_for t

				csv << t.csv_output
				summarize t
				pbar.inc
			end
		end
		pbar.finish
		print "\n\nCompleted modeling excerise\n\n".green	
		
		calculate_orders(false) if run_orders == 'Y'
		
		write_output_files
	end
	
	def summarize(t)
	
		#increment the high vs. low cost difference so we can report on it later
		@high_low_cost_diff = @high_low_cost_diff + (t.high_cost_fee - t.low_cost_fee) unless t.high_cost_fee.nil? || t.low_cost_fee.nil? #v1.8
		
		@unique_amounts_by_mcc.merge! t.mcc => {} unless @unique_amounts_by_mcc[t.mcc]
		@unique_amounts_by_mcc[t.mcc].merge! t.regulated => {} unless @unique_amounts_by_mcc[t.mcc][t.regulated]
		@unique_amounts_by_mcc[t.mcc][t.regulated].merge! t.amount => 0 unless @unique_amounts_by_mcc[t.mcc][t.regulated][t.amount]
		@unique_amounts_by_mcc[t.mcc][t.regulated][t.amount] += 1
		
		orignal_network_name = @networks[t.original_network.to_i]['display_name'] unless t.original_network.nil?
		low_cost_network_name = @networks[t.low_cost_network.to_i]['display_name'] unless t.low_cost_network.nil?
		routing_network_name = @networks[t.routing_network.to_i]['display_name'] unless t.routing_network.nil?
		low_bid_network_name = @networks[t.low_bid_network.to_i]['display_name'] unless t.low_bid_network.nil?
	
		#@summary_chart_data
		if t.in_bin_file == 1
			update_summary_chart_data 2, 'left', 1
			
			if t.low_cost_fee.nil?
				update_summary_chart_data(3, 'mid', 1)
			else
				update_summary_chart_data(3, 'left', 1)
			end
		else
			update_summary_chart_data 2, 'mid', 1
			update_summary_chart_data 3, 'right', 1
		end
		
		#@signature_summary and @network_summary and @network_differences and @chunked_network_orders and @routing_summary
		if t.in_bin_file == 1
			#create the structure
		
			#v1.11 - A new pinless summary file has been added
			amount_bucket = '<15' if t.amount< 15.00
			amount_bucket = '>50' if t.amount > 50.00
			amount_bucket = '15 - 50' if t.amount >= 15.00 and t.amount <= 50.00
			@pinless_summary.merge! orignal_network_name => Hash.new unless @pinless_summary[orignal_network_name]
			@pinless_summary[orignal_network_name].merge! low_cost_network_name => Hash.new unless @pinless_summary[orignal_network_name][low_cost_network_name]
			@pinless_summary[orignal_network_name][low_cost_network_name].merge! t.pinless => Hash.new unless @pinless_summary[orignal_network_name][low_cost_network_name][t.pinless]
			@pinless_summary[orignal_network_name][low_cost_network_name][t.pinless].merge! amount_bucket => {'number_of_transactions' => 0, 'total_amount' => 0.0} unless @pinless_summary[orignal_network_name][low_cost_network_name][t.pinless][amount_bucket]
			@pinless_summary[orignal_network_name][low_cost_network_name][t.pinless][amount_bucket]['number_of_transactions'] +=1
			@pinless_summary[orignal_network_name][low_cost_network_name][t.pinless][amount_bucket]['total_amount'] += t.amount
			
			
			@network_summary.merge! low_cost_network_name => Hash.new unless @network_summary[low_cost_network_name]
			@network_summary[low_cost_network_name].merge! orignal_network_name => {'fees' => 0.0,'premier' => 0, 'reg_no_fraud' => 0, 'reg_with_fraud' => 0, 'total_transactions' => 0, 'amount' => 0.0} unless @network_summary[low_cost_network_name][orignal_network_name]
			
			#and add the numbers in
			asset_temp_indicator = t.low_cost_network[-3,3]
			asset = asset_temp_indicator[0,1]
			#asset = t.low_cost_network[-1..-1] #get second to last character from the lost cost network
			@network_summary[low_cost_network_name][orignal_network_name]['fees'] += t.low_cost_fee
			@network_summary[low_cost_network_name][orignal_network_name]['premier'] += 1 if @assets[asset][2,1] == '1'
			@network_summary[low_cost_network_name][orignal_network_name]['reg_no_fraud'] += 1 if @assets[asset][0,2] == '10'
			@network_summary[low_cost_network_name][orignal_network_name]['reg_with_fraud'] += 1 if @assets[asset][0,2] == '11'
			@network_summary[low_cost_network_name][orignal_network_name]['total_transactions'] += 1
			@network_summary[low_cost_network_name][orignal_network_name]['amount'] += t.amount
			
			#create the structure
			@network_differences.merge! low_cost_network_name => {'low_total_transactions' => 0, 'orig_total_transactions' => 0, 'low_total_fees' => 0.0, 'orig_total_fees' => 0.0, 'low_total_amount' => 0.0, 'orig_total_amount' => 0.0} unless @network_differences[low_cost_network_name]
			@network_differences.merge! orignal_network_name => {'low_total_transactions' => 0, 'orig_total_transactions' => 0, 'low_total_fees' => 0.0, 'orig_total_fees' => 0.0, 'low_total_amount' => 0.0, 'orig_total_amount' => 0.0} unless @network_differences[orignal_network_name]
			
			#and add the numbers in
			@network_differences[low_cost_network_name]['low_total_transactions'] += 1
			@network_differences[low_cost_network_name]['low_total_fees'] += t.low_cost_fee unless t.low_cost_fee.nil?
			@network_differences[low_cost_network_name]['low_total_amount'] += t.amount unless t.amount.nil?

			@network_differences[orignal_network_name]['orig_total_transactions'] += 1
			@network_differences[orignal_network_name]['orig_total_fees'] += t.original_fee unless t.original_fee.nil?
			@network_differences[orignal_network_name]['orig_total_amount'] += t.amount unless t.amount.nil?
			
			#@routing_summary
			@routing_summary.merge! orignal_network_name => Hash.new unless @routing_summary[orignal_network_name]
			@routing_summary[orignal_network_name].merge! routing_network_name => {:transaction_count => 0, :fees => 0.0} unless @routing_summary[orignal_network_name][routing_network_name]
			@routing_summary[orignal_network_name][routing_network_name][:transaction_count] += 1
			@routing_summary[orignal_network_name][routing_network_name][:fees] += t.routing_network_fee unless t.routing_network_fee.nil?
			
			#@chunked_network_orders
			@chunked_network_orders[t.regulated.to_s].each do |value|
				if t.amount.to_i >= value[:low_amount] && t.amount.to_i <= value[:high_amount]
					value[:transaction_count] += 1
					break #found the correct range...so we are done and no need to loop anymore
				end
			end
		end
		
		#@fee_summary
		#create the structure. since the @fee_summary has both original and low cost network we need to merge in both of them so we can add the numbers in accordingly
		@fee_summary.merge! low_cost_network_name => {'total_original_transactions' => 0, 'non_pin_debit_count' => 0, 'not_routable_now' => 0, 'original_transactions_included_in_analysis' => 0, 'original_fees' => 0.0, 'low_cost_count' => 0, 'low_cost_fees' => 0, 'fee_variance' => 0.0, 'low_bid_count' => 0, 'low_bid_fees' => 0.0} unless @fee_summary[low_cost_network_name]
		@fee_summary.merge! orignal_network_name => {'total_original_transactions' => 0, 'non_pin_debit_count' => 0, 'not_routable_now' => 0, 'original_transactions_included_in_analysis' => 0, 'original_fees' => 0.0, 'low_cost_count' => 0, 'low_cost_fees' => 0, 'fee_variance' => 0.0, 'low_bid_count' => 0, 'low_bid_fees' => 0.0} unless @fee_summary[orignal_network_name]
		@fee_summary.merge! low_bid_network_name => {'total_original_transactions' => 0, 'non_pin_debit_count' => 0, 'not_routable_now' => 0, 'original_transactions_included_in_analysis' => 0, 'original_fees' => 0.0, 'low_cost_count' => 0, 'low_cost_fees' => 0, 'fee_variance' => 0.0, 'low_bid_count' => 0, 'low_bid_fees' => 0.0} unless @fee_summary[low_bid_network_name]
		
		
		#and add the numbers in
		@fee_summary[low_cost_network_name]['low_cost_count'] += 1 if t.in_bin_file == 1 && !t.original_fee.nil?
		@fee_summary[low_cost_network_name]['low_cost_fees'] += t.low_cost_fee if t.in_bin_file == 1 && !t.original_fee.nil?
		@fee_summary[low_cost_network_name]['fee_variance'] += t.low_cost_fee  if t.in_bin_file == 1 && !t.original_fee.nil?
		
		@fee_summary[orignal_network_name]['total_original_transactions'] += 1
		@fee_summary[orignal_network_name]['non_pin_debit_count'] += 1 if t.in_bin_file == 0
		@fee_summary[orignal_network_name]['not_routable_now'] += 1 if t.original_fee.nil? and t.in_bin_file == 1
		@fee_summary[orignal_network_name]['original_transactions_included_in_analysis'] += 1 if t.in_bin_file == 1 && !t.original_fee.nil?
		@fee_summary[orignal_network_name]['original_fees'] += t.original_fee if t.in_bin_file == 1 && !t.original_fee.nil?
		@fee_summary[orignal_network_name]['fee_variance'] -= t.original_fee if t.in_bin_file == 1 && !t.original_fee.nil?
		
		@fee_summary[low_bid_network_name]['low_bid_count'] += 1 if t.in_bin_file == 1 && !t.original_fee.nil?
		@fee_summary[low_bid_network_name]['low_bid_fees'] += t.low_bid_fee if t.in_bin_file == 1 && !t.original_fee.nil?
		
	end
	
	def update_summary_chart_data(row, col, value)
		@summary_chart_data[row][col]['value'] += value
	end
	
	def write_output_files
		#@summary_chart_data
		CSV.open(@client_output_dir + 'summary_chart.csv', 'wb') do |csv|
			csv << ['row', 'type', 'label', 'value']
			
			@summary_chart_data.each do |row, row_value|
				row_value.each do |col, col_value|
					csv << [row, col, col_value.values].flatten
				end
			end
		end
		

		#v1.11 - @pinless_summary 
      CSV.open(@client_output_dir + 'pinless_summary.csv', 'wb') do |csv|
      #csv << ['original_network', 'pinless_eligible', 'amount_bucket', 'number_of_transactions', 'total_amount']
      csv << ['original_network', 'low_cost_network_name', 'pinless_eligible', 'amount_bucket', 'number_of_transactions', 'total_amount']
      
     @pinless_summary.each do |network, values0|
      values0.each do |low_cost_network_name, values1|
        values1.each do |pinless, values2|
        values2.each do |amount_bucket, values|
        csv << [network, low_cost_network_name, pinless, amount_bucket, values.values].flatten
        end
        end
      end
   end
    end
    	
		#@network_summary
		CSV.open(@client_output_dir + 'network_summary.csv', 'wb') do |csv|
			csv << ['lowest_cost_network_name', 'original_network_name', 'fees', 'premier_transactions', 'regulated_no_fraud_transactions', 'regulated_with_fraud_transactions', 'total_transactions', 'amount']
			
			@network_summary.each do |low, low_value|
				low_value.each do |orig, orig_value|
					csv << [low, orig, orig_value.values].flatten
				end
			end
		end
		
		#client data
		CSV.open(@client_output_dir + 'client.csv', 'wb') do |csv|
			high_low_diff = @high_low_cost_diff.nil? ? nil : sprintf("%.6f", @high_low_cost_diff)
			csv << ['name','comments','annual_multiplier','annual_multiplier_unit', 'sr_per_trans_fee', 'original_network_provided', 'high_low_cost_diff']
			csv << [@profile['info']['name'], @profile['info']['comments'], @profile['info']['annual_multiplier'], @profile['info']['annual_multiplier_unit'], @profile['info']['sr_per_trans_fee'], @profile['info']['original_network_provided'], high_low_diff]
		end
		
		#profile data
		CSV.open(@client_output_dir +  'profile.csv', 'wb') do |csv|
			csv << ['network_name', 'fee_type', 'tier', 'description']
			@profile['details'].each do |id, values|
				next if @networks[id]['premier'] == '1' #don't really need to call out the premier networks separately.
				name = @networks[id]['display_name']
				csv << [name, 'Interchange', values['interchange'], values['interchange_name']]
				csv << [name, 'Switch', values['switch'], values['switch_name']]
				csv << [name, 'Registered', values['registered'], values['registered_name']]
			end
		end
		
		#@fee_summary
		CSV.open(@client_output_dir + 'fee_summary.csv', 'wb') do |csv|
			csv << ['network_name', 'total_original_transactions', 'non_pin_debit_count', 'not_routable_now', 'original_transactions_included_in_analysis', 'original_network_fees', 'low_cost_transactions', 'low_cost_network_fees', 'low_bid_transactions', 'low_bid_network_fees', 'fee_variance']
			@fee_summary.each do |key, value|
				csv << [key, value['total_original_transactions'], value['non_pin_debit_count'], value['not_routable_now'], value['original_transactions_included_in_analysis'], value['original_fees'], value['low_cost_count'], value['low_cost_fees'], value['low_bid_count'], value['low_bid_fees'], value['fee_variance']]
			end
		end		
		
		#@network_differences
		CSV.open(@client_output_dir + 'network_differences.csv', 'wb') do |csv|
			csv << ['network_name', 'low_total_transactions', 'orig_total_transactions', 'low_total_fees', 'orig_total_fees', 'low_total_amount', 'orig_total_amount']
			@network_differences.each do |key, value|
				csv << [key, value['low_total_transactions'], value['orig_total_transactions'], value['low_total_fees'], value['orig_total_fees'], value['low_total_amount'], value['orig_total_amount']]
			end
		end	

		#@routing_summary
		CSV.open(@client_output_dir + 'routing_networks.csv', 'wb') do |csv|
			csv << ['original_network', 'routing_network','transaction_count','fees']
			
			@routing_summary.each do |original_name, helper|
				helper.each do |network_name, value|
					csv << [original_name, network_name, value[:transaction_count], sprintf("%.6f",value[:fees])]
				end
			end
		end
		
		write_output_file_for_orders
	end
	
	def write_output_file_for_orders
		#@chunked_network_orders
		CSV.open(@client_output_dir + 'order_ranges.csv', 'wb') do |csv|
			csv << ['type', 'mcc', 'regulated', 'transaction_count', 'low_amount', 'high_amount', 'network_order']
			
			@chunked_network_orders.each do |type, regs|
				regs.each do |reg, values|
					values.each do |value|
						csv << [value[:type], value[:mcc], value[:regulated], value[:transaction_count], value[:low_amount], value[:high_amount], value[:order]]
					end
				end
			end
		end		
	end
	
	def get_attribute(asset_indicator, attribute)
	
		values = @assets[asset_indicator]
		case attribute
			when 'regulated'
				return values[0,1]
			when 'fraud'
				return values [1,1]
			when 'premier'
				return values [2,1]
		end
		
		return nil
	end
	
	 def get_pin_indicator(pin_indicator, attribute)
  
		values = @pin_inds[pin_indicator]
		case attribute
		  when 'pin'
			return values[0,1]
		  when 'pinless_pos'
			return values [1,1]
		  when 'pinless_billpay'
			return values [2,1]
		end
		
		return nil
  end
	
	def sniff(path)
		common_delimiters = [",","\t", "|"]
		first_line = File.open(path).first
		return nil unless first_line
		snif = {}
		common_delimiters.each {|delim|snif[delim]=first_line.count(delim)}
		snif = snif.sort {|a,b| b[1]<=>a[1]}
		snif.size > 0 ? snif[0][0] : nil
	end
	
	def parse_csv
	
		prepare_for_processing
		flag = 1
		flag = ask "Is this for a pin or pinless? (0 for pin, 1 for pinless)?"
		filename = ask "\n\nProvide CSV filename to parse: "
		out = ask "\n\nProvide output CSV filename: "
		
		filename = @client_dir + filename
		out = @client_dir + out
		
		questions = {	
						'ccn' => 'We cannot proceed without a card number. Please try again. Exiting',
						'amount' => 'We cannot proceed without an amount. Please try again. Exiting',
						'mcc' => 'The mcc column is missing. Please enter a default MCC code to use. ',
						'pan' => 'The pan column is missing. Please enter 0 to use the number of digits in the ccn column or enter the default PAN to use. ',
						'original_network' => 'The original_network column is missing. Please enter the original network ID you wish to use or just hit enter to leave blank. '
					}
					
		if flag == '0'
		  output_columns = {'ccn' => {'num' => 1, 'col' => 0, 'default' => nil},'pan' => {'num' => 2, 'col' => 0, 'default' => 16},'amount' => {'num' => 3, 'col' => 0, 'default' => nil},'mcc' => {'num' => 4, 'col' => 0, 'default' => nil},'original_network' => {'num' => 5, 'col' => 0, 'default' => nil}}
		else
		  output_columns = {'ccn' => {'num' => 1, 'col' => 0, 'default' => nil},'pan' => {'num' => 2, 'col' => 0, 'default' => 16},'amount' => {'num' => 3, 'col' => 0, 'default' => nil},'mcc' => {'num' => 4, 'col' => 0, 'default' => nil},'original_network' => {'num' => 5, 'col' => 0, 'default' => nil},'int_rate' => {'num' => 6, 'col' => 0, 'default' => nil},'disc_amt' => {'num' => 7, 'col' => 0, 'default' => nil}}
		end
		num_values_before_col_is_variable = 40
		variable_cols = []


		unique_values = []
		row_col_counts = {}
		num_rows = 0
		num_cols = 0
		num_rows_with_different_cols_counts = 0
		first = true
		networks_provided = false
		header_row_exists = false
		headers = []
		
		#get the network list we wish to use...which will only be those networks which have a routable_id equal to their own id
		#this may not be needed...all depends on if a network column is provided or not
		network_list = @networks.select { |k,v| v['rateable_network'] == 1 }
		mapped_network_list = Hash.new

		CSV.foreach(filename, :col_sep => sniff(filename)) do |row|

			if first
				num_cols = row.length
				row.each { |h| puts h.strip.green }
				header_row_exists = ask 'Is the above data a header row or data row (1 for header, 0 for data)? '
				first = false
				headers = row.map { |cell| cell.dup } #copy the first row into a header array
				next if header_row_exists #just skip processing of this iteration since this is a header row
			end
			
			
			#this section will give us the unique column counts...in case there are some rows with more columns that the first row
			row_col_counts.merge! row.length => 0 unless row_col_counts[row.length]
			row_col_counts[row.length] += 1
			num_rows_with_different_cols_counts += 1 if !first && num_cols != row.length

			unless  num_cols != row.length #dont want to parse rows that don't have the same number of columns. they will be written out to parseerror.csv later
				num = 0
				row.each do |item|
					unless variable_cols.include? num
						item = '<blank>' if item.nil? #default to something if nil
						item.strip! #remove leading and trailing whitespace 
						
						if unique_values[num].nil?
							unique_values[num] = [item]
						else
							unique_values[num] << item unless unique_values[num].include? item
							if unique_values[num].length > num_values_before_col_is_variable 
								variable_cols << num
							end
						end

						#num += 1
					end
					num += 1
				end
			end
			
			num_rows += 1
		end
	
		#now we need to determine the column mappings
		col_num = 1
		unique_values.each do |col|
			system('cls')
			puts headers[col_num - 1].to_s.green if header_row_exists
			puts '**********************************'.green
			col.each { |item| puts item.green }
			puts '**********************************'.green
			puts '**********************************'.red
			puts '0. skip/ignore'.red
			output_columns.each { |k,v| puts (v['num'].to_s + '. ' + k).red if v['col'] == 0 }
			puts '**********************************'.red
			puts "\n\n"
			input = ask "What column does this data represent (enter the # above)? "
			output_columns.each { |k,v| v['col'] = col_num if v['num'].to_s == input}
			
			#if original_network was selected by the user we need to map the IDs to the data provided
			if input == '5' 
				networks_provided = true
				ids = ask "Are the networks provided as names or IDs (0 for names, 1 for IDs)? "
				
				if ids == '0' #if they are names we need to map to IDs
					puts "Okay. We need to map the data provided to the IDs. Let's do that now.".green
					sleep 5
					col.each do |item|
						system('cls')
						puts '**********************************'.green
						puts '0 - Ignore (rows with this network will not be processed)'.green
						network_list.each { |k,v| puts "#{k} - #{v['display_name']}".green }
						puts '**********************************'.green
						id = ask "What ID should this map to: #{item}? "
						mapped_network_list.merge! item => id
					end
				else #if they are IDs we need to just map the ID to the ID so our lives are easier when we write the data out
					col.each do |item|
						mapped_network_list.merge! item => item
					end
				end
			end
				

			col_num += 1
		end
		
		#and then for the columns that were not provided we need to know what to do with them
		system('cls')
		puts "here"
		output_columns.each do |k,v|
			if v['col'] == 0 #if this column was not choosen by the user we need more details
				v['default'] = ask questions[k]
				exit if k == 'ccn' || k == 'amount' #we MUST have a CCN and an amount...or we can't do anything with the smart routing model.
			end
			system('cls')
		end
	
		error_rows = 0
		#now write the output files
		CSV.open(@client_dir + 'parseerror.csv', 'wb') do |error_csv|
			CSV.open(out, 'wb') do |csv|
				csv << output_columns.keys
				
				first = true
				CSV.foreach(filename, :col_sep => sniff(filename)) do |row|
					
					catch :next_row do
						#we don't want to write out a header row since we already did that above
						if first
							first = false
							next if header_row_exists
						end
						
						arr = []
					
						if row.length != num_cols #write to error file
							error_csv << ['error: number of columns do not match'] + row
							error_rows += 1
						else #or if all is okay write to output file...need to map the columns to the required output format of course
							output_columns.each do |k,v|
								value = nil
								if v['col'] > 0 #meaning if data was provided and we didn't have to use a default value
									value = row[v['col'] - 1]
									value.strip! unless value.nil?
									
									if value.nil? && k != 'original_network' #if the value is blank and this is NOT the original network row
										error_csv << ['error: value is blank that cannot be blank'] + row	#write out to the error file since we can't have blank cells
										error_rows += 1
										throw :next_row	    #and move along to the next row
									end
									
									if networks_provided && k == 'original_network' #handle the case of the network
										value = mapped_network_list[value]
										throw :next_row if value == '0' #if the user told us to ignore the network we need to not export the rows associated with that network
									end
									
								else #v['col'] == 0 #handle some default values
									if k == 'pan' && v['default'].to_s == '0'
										value = row[output_columns['ccn']['col'] - 1].strip.length
									else
										value = v['default'] 
									end
								end
								
								arr << value
							end
							csv << arr
						end
					end #we end up here if :next_row is thrown...basically skipping the row (or part of the row) in question
				end

			end
		end

		File.delete(@client_dir + 'parseerror.csv') if error_rows == 0
		puts "There were #{error_rows} row(s) that had errors.\nThose rows have been written to parseerror.csv.\nPlease copy the error file, rename it, fix the errors and re-combine the files.".red if error_rows > 0	
		puts "number of rows in data file = #{num_rows}".green
		puts "\n\nComplete.".green
	end
	
	def combine_csv(one, two, out)
	
		#pretty self explanatory...
		CSV.open(out, 'wb') do |out_csv|
			CSV.foreach(one, :col_sep => sniff(one)) do |one_csv|
				out_csv << one_csv
			end

			CSV.foreach(two, :col_sep => sniff(one), :headers => true) do |two_csv| #this will stop the header row from being included in the output
				out_csv << two_csv
			end			
			
		end
		
		puts "\n\nCompleted combination.\n\n".green
	
	end
	
	def download_pin_debit_bin_files
		agent = Mechanize.new
		agent.verify_mode = OpenSSL::SSL::VERIFY_NONE
		agent.user_agent_alias = 'Windows IE 6'

		#base_url = 'https://www.mftcat.firstdataclients.com'  #test
		base_url = 'https://www.mft1.firstdataclients.com'

		login = agent.get base_url + '/cgi-bin/messageway/mwi.cgi'

		#login.form_with(:name => 'logonform') { |form| form.user = 'MNOT-001233' }  #test
		#login.form_with(:name => 'logonform') { |form| form.password = '$m4rtr0ut1ng1' }  #test

		login.form_with(:name => 'logonform') { |form| form.user = @options['bin_file_download_user'] }
		login.form_with(:name => 'logonform') { |form| form.password = @options['bin_file_download_password'] }

		reports = login.form_with(:name => 'logonform').click_button

		available = agent.get base_url + '/cgi-bin/messageway/mwi.cgi?request=ViewAvailable'
		downloaded = agent.get base_url + '/cgi-bin/messageway/mwi.cgi?request=ViewDownloaded'

		(available.links + downloaded.links).each do |link|
			#if link.href.include?('ZipDownload') && link.href.include?('GASADRB6')  #test
			if link.href.include?('ZipDownload') && link.href.include?('GASX233A')
				file = agent.get base_url + link.href
				file.save! './inputs/pin_debit_bin_files/' + file.filename #save! will overwrite while save adds a number to the end of the filename
			end
		end	
	end
	
	def add_network_to_orders(combo, network, fee)	
		@orders.merge! combo => [] unless @orders[combo]
		@orders[combo] << {:network => network, :fee => sprintf("%.6f",fee)} #only using 6 decimal points so we don't sort differently for the same fee
	end

	def sort_networks_for_combo(combo) #sort on fee and if the fee is the same sort on network id (not the name!)
		@orders[combo].sort! do |x,y| 
			order = x[:fee] <=> y[:fee]
			order == 0 ? x[:network] <=> y[:network] : order
		end
	end
	
	def calculate_orders(independent)
	
		#start with a clean slate...in case the user does multiple model runs in the same session (doesn't exit out first and re-enter)
		@orders.clear
		@unique_network_orders.clear
		@chunked_network_orders.clear
		#@unique_network_orders = {'0' => {}, '1' => {}} 
		#@chunked_network_orders = {'0' => [], '1' => []}
		
		max = 10000
		#amounts = (0..max) #commented out as part of v1.5
		amounts = []
		regulateds = ['0', '1']
		mccs = []
		prepaids = ['0']
		types = ['billable', 'bid']
		
		#we need to determine the client and profile and load rates/bins if this method is being called indpendent of processing transactions
		if independent
			prepare_for_processing
			mcc_input = ask 'Enter MCCs (separated by commas). '
			
			#additions as part of v1.5
			amounts_input = ask 'Enter amounts in pennies (ex. 0..10000,10232)  or just hit enter for default. '
			
			if amounts_input.empty? || amounts_input.nil?
				amounts = (0..max).to_a
			else
				amounts = get_array_of_values_given_input_string(amounts_input)
			end
			#end v1.5 additions
			
			mccs = mcc_input.split(',').map! { |mcc| mcc.strip }
		else
			mccs = @unique_amounts_by_mcc.keys #gets all unique MCCs from the transactions we processed
		end
		
		permutations = amounts.length * mccs.length * regulateds.length * prepaids.length  * @rate_tree.keys.length * types.length
		print "Commencing order calculations.\n\n".green
		
		pbar = ProgressBar.new("Orders", permutations)
		pbar.bar_mark = '='
		
		types.each do |type|
			amounts.each do |amount|
				regulateds.each do |regulated|
					mccs.each do |mcc|
						prepaids.each do |prepaid|
								combo = "#{type}|#{amount}|#{mcc}|#{regulated}|#{prepaid}"
								@rate_tree.keys.each do |network|
									fraud = regulated == '0' ? '0' : '1' #if unregulated then set fraud to 0. if regulated then set fraud to 1
									pre_auth = @options['pre_auth_mccs'].include?(mcc.to_i) ? '1' : '0' 
									registered = @networks[network]['registered'].to_s
									mcc_helper = @rate_tree[network].keys.include?(mcc) ? mcc : '*'
									interchange_tier = @networks[network]['interchange']
									switch_tier = @networks[network]['switch']
									tiers = interchange_tier == 'null' ? 'null' : [interchange_tier, switch_tier] #if there are no interchange tiers then there are no switch tiers either...at least so far!
									fees = traverse(@rate_tree[network], [mcc_helper,registered, regulated, fraud, prepaid, pre_auth, tiers]) #mcc, registered, regulated, fraud, premier, prepaid, pre_auth, tiers
									fees.flatten!
									fees.uniq!
									
									total_fee = 0.0
									fees.each { |f| total_fee += f.calculate(Transaction.new(:amount => amount / 100.0), fraud, type) }
									
									add_network_to_orders combo, network, total_fee unless total_fee == 0
									
									pbar.inc
								end
								
								sort_networks_for_combo combo
						end
					end
				end
			end
		end
		pbar.finish
		print "\n\nCompleted order calculations.\n\n".green
		
		pp @client_output_dir
		CSV.open(@client_output_dir + 'order_ranges_details.csv', 'wb') do |csv|
			csv << ['type', 'mcc', 'regulated', 'amount', 'order_details']
			#now transform the orders into the chunked data we will need to output
			@orders.each do |key, value|
				type, amount, mcc, regulated, prepaid = key.split('|')
			
				amount = amount.to_i
				orders = ''
				unique_helper = ''
				value.each do |row|
					network = row[:network]
					fee = row[:fee]
					orders += @networks[network]['display_name'] + '=>' + sprintf("%.6f",fee.to_s) + '|'
					unique_helper += @networks[network]['display_name'] + '>'
					
				end
				csv << [type, mcc, regulated, amount / 100.0, orders[0..-2]]
				
				unique_helper = unique_helper[0..-2] #remove last character
				
				@unique_network_orders.merge! type => {} unless @unique_network_orders[type]
				@unique_network_orders[type].merge! mcc => {} unless @unique_network_orders[type][mcc]
				@unique_network_orders[type][mcc].merge! regulated => {} unless @unique_network_orders[type][mcc][regulated]
				@unique_network_orders[type][mcc][regulated].merge! unique_helper => [] unless @unique_network_orders[type][mcc][regulated][unique_helper]
				@unique_network_orders[type][mcc][regulated][unique_helper] << amount
			end
		end
			
		#now we need to "chunk" the data to get it into ranges instead of all consecutive numbers
		#basically turn this: [1,2,4,5,6,7,9,13]
		#into this: [[1,2],[4,7],[9,9],[13,13]]
		@unique_network_orders.each do |type, mccs|
			mccs.each do |mcc, regs|
				regs.each do |reg, value|
					value.each do |order, amounts|
						amounts.to_enum(:chunk).with_index { |x, idx| x - idx }.map do |diff, group|
							high_amount = group.last.to_i
							high_amount = 1000000000 if high_amount == max #change $100 to $10,000,000 but we are dealing in cents right now
							high_amount = high_amount / 100.0
							low_amount = group.first.to_i / 100.0
							
							@chunked_network_orders.merge! type => {} unless @chunked_network_orders[type]
							@chunked_network_orders[type].merge! reg => [] unless @chunked_network_orders[type][reg]
							@chunked_network_orders[type][reg] << {:type => type, :mcc => mcc, :transaction_count => num_transactions_in_amount_range(mcc, reg, low_amount, high_amount), :regulated => reg, :low_amount => low_amount, :high_amount => high_amount, :order => order } #100% taken from http://stackoverflow.com/questions/8621733/how-do-i-summarize-array-of-integers-as-an-array-of-ranges
						end
					end
				end
			end
		end
			
		write_output_file_for_orders if independent
	end

	def num_transactions_in_amount_range(mcc, reg, low, high)
		
		amt = 0
		begin
			@unique_amounts_by_mcc[mcc][reg].each do |amount, count|
				amt += count if amount.to_f >= low && amount.to_f <= high.to_f
			end
		rescue
			amt = 0
		end
		
		amt
	end
	
	def get_array_of_values_given_input_string(str)
		values = []
		str.split(',').each do |v|
			if v.include? '..'
				ends = v.split('..').map{ |i| Integer(i.strip) }
				values += (ends[0]..ends[1]).to_a
			else
				values << v.strip.to_i
			end
		end
		values
	end
	
	private :num_transactions_in_amount_range, :update_summary_chart_data, :summarize, :write_output_files, :get_attribute, :sniff, :set_routable_network_on, :add_network_to_orders, :sort_networks_for_combo
end

class Transaction
	
	#v1.8 - added :high_cost_network, :high_cost_fee to attr_accessor
	attr_accessor :ccn, :pan, :mcc, :amount, :original_network, :int_rate, :disc_amt, :low_cost_network, :low_bid_network, :original_fee, :low_cost_fee, :low_bid_fee, :billable_network_fees, :bid_network_fees, :in_bin_file, :regulated, :fraud, :premier, :prepaid, :pinless, :pre_authable, :routing_network, :routing_network_fee, :high_cost_network, :high_cost_fee, :networks_bef_deletion
	def initialize(attrs = {})
		attrs.each do |k,v|
			self.send "#{k}=", v
		end
	end
	
	
	def self.headers
		#v1.8 - added high_cost_network and high_cost_fee to headers
		
		if @pin_flag == '0'
    ['ccn','pan','mcc', 'amount', 'original_network', 'low_cost_network', 'low_bid_network', 'routing_network', 'high_cost_network', 'original_fee', 'low_cost_fee', 'low_bid_fee', 'routing_network_fee', 'high_cost_fee', 'in_bin_file', 'regulated', 'fraud', 'premier', 'prepaid', 'pinless_eligible', 'networks_bef_deletion','all_network_fees']
    else
   ['ccn','pan','mcc', 'amount', 'original_network', 'int_rate', 'disc_amt', 'low_cost_network', 'low_bid_network', 'routing_network', 'high_cost_network', 'original_fee', 'low_cost_fee', 'low_bid_fee', 'routing_network_fee', 'high_cost_fee', 'in_bin_file', 'regulated', 'fraud', 'premier', 'prepaid', 'pinless_eligible', 'networks_bef_deletion','all_network_fees']
    end
		#['ccn','pan','mcc', 'amount', 'original_network', 'int_rate', 'disc_amt', 'low_cost_network', 'low_bid_network', 'routing_network', 'high_cost_network', 'original_fee', 'low_cost_fee', 'low_bid_fee', 'routing_network_fee', 'high_cost_fee', 'in_bin_file', 'regulated', 'fraud', 'premier', 'prepaid', 'pinless_eligible', 'networks_bef_deletion','all_network_fees']
		
	end
	
	def csv_output
		low_cost = self.low_cost_fee.nil? ? nil : sprintf("%.6f",self.low_cost_fee)
		high_cost = self.high_cost_fee.nil? ? nil : sprintf("%.6f",self.high_cost_fee) #v1.8
		low_bid = self.low_bid_fee.nil? ? nil : sprintf("%.6f",self.low_bid_fee)
		original = self.original_fee.nil? ? nil : sprintf("%.6f",self.original_fee)
		routing_network_fee = self.routing_network_fee.nil? ? nil : sprintf("%.6f",self.routing_network_fee)
		amt = self.amount.nil? ? nil : sprintf("%.2f",self.amount)
		
		all_network_fees = ''
		self.billable_network_fees.each do |k,v|
			all_network_fees += k.to_i.to_s + '=>' + sprintf("%.6f",v.to_s) + '|'
		end
#		#puts self.prepaid
		#v1.8 - added high_cost_network and high_cost_fee to output
		 
		#[self.ccn.to_s, self.pan.to_s, self.mcc.to_s, amt, self.original_network.to_s, self.low_cost_network.to_i.to_s, self.low_bid_network.to_i.to_s, self.routing_network.nil? ? nil : self.routing_network.to_i.to_s, self.high_cost_network.nil? ? nil : self.high_cost_network.to_i.to_s, original, low_cost, low_bid, routing_network_fee, high_cost, self.in_bin_file, self.regulated, self.fraud, self.premier, self.prepaid, all_network_fees[0..-2]]
		if @pin_flag == '0'
		  [self.ccn.to_s, self.pan.to_s, self.mcc.to_s, amt, self.original_network.to_s, self.low_cost_network.to_i.to_s, self.low_bid_network.to_i.to_s, self.routing_network.nil? ? nil : self.routing_network.to_i.to_s, self.high_cost_network.nil? ? nil : self.high_cost_network.to_i.to_s, original, low_cost, low_bid, routing_network_fee, high_cost, self.in_bin_file, self.regulated, self.fraud, self.premier, self.prepaid, self.pinless, self.networks_bef_deletion, all_network_fees[0..-2]]
		else
		[self.ccn.to_s, self.pan.to_s, self.mcc.to_s, amt, self.original_network.to_s, int_rate, disc_amt, self.low_cost_network.to_i.to_s, self.low_bid_network.to_i.to_s, self.routing_network.nil? ? nil : self.routing_network.to_i.to_s, self.high_cost_network.nil? ? nil : self.high_cost_network.to_i.to_s, original, low_cost, low_bid, routing_network_fee, high_cost, self.in_bin_file, self.regulated, self.fraud, self.premier, self.prepaid, self.pinless, self.networks_bef_deletion, all_network_fees[0..-2]]
	end
	end
	
	
end

module Comparable

  def at_least other; self < other ? other : self end
  def at_most other; self > other ? other : self end
end

class Fee
	
	attr_accessor :fee_type, :price_type, :fixed, :percent, :min, :max, :fraud, :sign, :threshold, :bid_fee
	
	def initialize(attrs = {})
		attrs.each do |k,v|
			self.send "#{k}=", v
		end
	end
	
	#calculate will be called A LOT. trying to make this function super fast helps speed up overall execution
	def calculate(t, fraud, type)
#		pp "1"
		return 0.0 if type == 'billable' && self.bid_fee #if this fee is a bid fee and we are not looking at the bid fees then return 0, else continue on
	#	pp "2"
  	
  	fee = self.fixed if self.price_type == 'F'
    
    fee = (self.fixed + (t.amount * self.percent) + (fraud == '1' ? self.fraud : 0)).at_least(self.min).at_most(self.max) if self.price_type == 'V' #calculate the fee
                                
    return fee if self.sign == '>=' && self.threshold == 0 #if there is no threshold to worry about get out quick...this is what happens the majority of the time
	
		#if we get here we know we are dealing with a variable fee
		#puts (self.fixed + (t.amount * self.percent) + (fraud == '1' ? self.fraud : 0)).at_least(self.min)
	#	fee = (self.fixed + (t.amount * self.percent) + (fraud == '1' ? self.fraud : 0)).at_least(self.min).at_most(self.max) #calculate the fee
	#	pp fee
	#	pp "3"
	#	return fee if self.sign == '>=' && self.threshold == 0 #if there is no threshold to worry about get out quick...this is what happens the majority of the time
		
		#otherwise we need to determine the sign and threshold before we can return
		case self.sign
			when '>'
			  #pp ">"
				return fee if t.amount > self.threshold
			when '>='
			  #pp ">="
				return fee if t.amount >= self.threshold
			when '<'
			  #pp "<"
				return fee if t.amount < self.threshold
			when '<='
			  #pp "<="
				return fee if t.amount <= self.threshold
			else
			  #pp "4"
				return 0.0
		end
		
		#if we get here then we have no idea what to do so just return 0
		return 0.0
	end

end