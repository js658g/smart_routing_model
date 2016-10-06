require 'pp'								#mostly used for debugging
#require 'smart_routing_model'				#the code compiled into a gem so ocra will work correctly
require './lib/smart_routing_model.rb'		#the SmartRoutingModel class
require 'highline/import' 					#for accepting user input from the command line
require 'win32console'    					#pre-req for colored
require 'colored'							#allows us to print in color on the command line


system ("cls") #clear the terminal window - obviously only works on windows...but since this will be compiled to an exe file it doesn't really matter
$model = SmartRoutingModel.new #global variable...just so we don't have to pass it to all the functions that we will be calling


def print_header
	print "************************************************\n"
	print "************************************************\n"
	print "First Data Smart Routing ROI Model\n"
	print "v" + SmartRoutingModel.version + " - Created by Thomas Rawley\n"
	print "First Data Confidential - Copyright 2015\n"
	print "************************************************\n"
	print "************************************************\n"
	print "\n"
	print "\n"
end

def print_options
	print "\n"
	print "Options\n"
	print "-----------------------------\n"
	print "1. Load New Rates\n"
	print "2. Load New BIN File\n"
	print "3. Download PIN Debit BIN Files from Message Way\n"
	print "4. Parse CSV File (transform into required input format for the model)\n"	
	print "5. Combine 2 CSV Files into 1 (formats exactly the same, including header row)\n"	
	print "6. Process Transactions\n"
	print "7. Calculate Orders\n"
	print "8. Exit\n"
	print "-----------------------------\n"
	print "\n"
end

def parse_option(option)
	
	case option
		when '1'
			filename = ask "\n\nProvide Rate CSV filename (just filename...no folder): "
			$model.load_rates(filename)
			print "\n\n"
			print "Successfully loaded rates.".green
			print "\n\n"
			return 1
		when '2'
			pin_filename = ask "\n\nProvide PIN Debit BIN Filename (just filename...no folder): "
			gbf_filename = ask "\nProvide Global BIN Filename (just filename...no folder): "
    	$model.load_bin_file(pin_filename, gbf_filename)
			print "\n\n"
			print "Successfully loaded BIN files.".green
			print "\n\n"
			return 1
		when '3'
			print "Attempting to download the files\n".green
			$model.download_pin_debit_bin_files
			print "Downloaded files will appear in inputs/pin_debit_bin_files folder.\n".green
			print "Find the most recent, unzip it, and import it.\n".green
			return 1
		when '4'
			$model.parse_csv
			return 1
		when '5'
			one = ask "\n\nProvide first CSV filename to combine (full path): "
			two = ask "\n\nProvide second CSV filename to combine (pull path): "
			out = ask "\n\nProvide output CSV filename (full path): "
			$model.combine_csv one, two, out
			return 1
		when '6'
			$model.process_transactions
			return 1
		when '7'
			$model.calculate_orders true
			return 1
		when '8'
			print "\n\n"
			print "Exiting".green
			print "\n\n"
			return 0
		else
			print "\n\n*****Invalid Command*****\n\n".red
			return 1 #don't know what to do so just start over
	end
	

rescue Exception => e
	print ("\n\n" + e.message + "\n\n").red_on_white
	e.backtrace.each do |line|
		print "\n".red_on_white
		print line.red_on_white
	end
	return 1
end


#-------------------------------
#-------------------------------
#Code execution begins here
#-------------------------------
#-------------------------------

print_header
while true #infinite loop that exits when the user selects the exit option
	print_options
	exit if parse_option(ask "Select Option: ") == 0
end


