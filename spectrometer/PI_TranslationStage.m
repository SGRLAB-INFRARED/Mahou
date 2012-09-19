classdef PI_TranslationStage < hgsetget

    properties
        Tag;
        center;
        scale;
        minimum;
        maximum;
        max_speed;
        comPort;
        terminator;
        type;
        baud;
        object;
        gui_object;
        ID;
        initialized;
        jogsize;
    end
        
    methods
        %port scale parent tag
        function obj = PI_TranslationStage(port, scale, gui_object_name)
            obj.initialized = 0;
            obj.center = 0;
            obj.scale = scale;
            obj.comPort = port;
            obj.terminator = {'LF','LF'};
            obj.type = 'serial';
            obj.gui_object = gui_object_name;
            obj.baud = 38400;

            obj.object = instrfind('Type', obj.type, 'Port', obj.comPort, 'Tag', '');

            % Create the serial port object if it does not exist
            % otherwise use the object that was found.
            if isempty(obj.object)
                obj.object = serial(obj.comPort);
            else
                fclose(obj.object);
                obj.object = obj.object(1);
            end

            % Connect to instrument object, obj1.
            fopen(obj.object);

            % Configure instrument object, obj1.
            set(obj.object, 'BaudRate', obj.baud);
            set(obj.object, 'Terminator', obj.terminator);

            try
                % %%
               
                obj.ID = obj.sendPIMotorCommand('*IDN?', 1);

                %minimum commandable position 
                [nums ~] = sscanf(obj.sendPIMotorCommand('TMN?', 1), '%i=%f');
                obj.minimum = nums(2)/obj.scale;
                %maximum commandable position
                [nums ~] = sscanf(obj.sendPIMotorCommand('TMX?', 1), '%i=%f');
                obj.maximum = nums(2)/obj.scale;
                %maximum commandable speed? TODO: test this
                [nums ~] = sscanf(obj.sendPIMotorCommand('VEL?', 1), '%i=%f');
                obj.max_speed = nums(2)/obj.scale

                %define 2-step macro
%                 obj.sendPIMotorCommand('MAC BEG TWO', 0);
%                 pause(1);
%                  obj.sendPIMotorCommand('MOV 1 $1', 0);
%                  pause(1);
%                  obj.sendPIMotorCommand('WAC ONT? 1=1', 0);
%                  pause(1);
%                  obj.sendPIMotorCommand('MOV 1 $2', 0);
%                  pause(1);
%                  obj.sendPIMotorCommand('WAC ONT? 1=1', 0);
%                  pause(1);
%                 obj.sendPIMotorCommand('MAC END', 0);
%                 pause(1);
                
                % check to see if macro is defined. This is tricky because
                % controller returns lines as separate answers (after a 
                % terminator) which confuses commands like query. As a
                % result it may either look like an error is present.
                %
                % resolve the problem by using lower level commands fprintf
                % and fscanf. Print the query string and an error request.
                % When the error request comes back with 0 we know we have
                % reached the end of the list
                fprintf(obj.object,'MAC?');
                fprintf(obj.object,'ERR?');
                flag_done = false;
                list = cell(1);
                count = 0;
                while ~flag_done
                    count = count+1;
                    ret = fscanf(obj.object,'%s');
                    if strcmp(ret,'0')
                        %if we reached the end
                        flag_done = true;
                    else
                        %otherwise add the result to the list
                        list{count} = ret;
                    end
                end
                if any(strcmpi(list,'TWOSTEP'))
                    disp('macro TWOSTEP defined');
                else
                    beep
                    fprintf(1,['PI controller macro TWOSTEP is not defined.\n\n'...
                    'Go To PI MikroMove and define a macro named TWOSTEP as:\n'...
                    'MOV 1 $1\n',...
                    'WAC ONT? 1=1\n',...
                    'MOV 1 $2\n',...
                    'WAC ONT 1=1\n']);
                end
                % reference move to negative limit
                obj.sendPIMotorCommand('RON 1 1', 0);
                obj.sendPIMotorCommand('SVO 1 1', 0);
                obj.sendPIMotorCommand('VEL 1 0.5', 0);
                obj.sendPIMotorCommand('FNL 1', 0);
                
                %Wait until motor gets to limit.
%                 while 1==1
%                     status = obj.sendPIMotorCommand('SRG? 1 1', 1);
%                     num = uint16(hex2dec(status(7:end-1)));
%                     if bitand(num, hex2dec('A000'))==hex2dec('8000')
%                         break;
%                     else
%                         pause(0.1);
%                     end
%                 end
                %at the limit switch consider the motor initialized. 
                obj.initialized = 1;

                %obj.initialized must =1 for is busy to work...
                while obj.IsBusy
                  drawnow
                  pause(0.1)
                end
                
                %Now we can load previous paramters
                %load last reset position
                LoadResetPosition(obj);
                
                %move to last reset position
                MoveTo(obj,guihandles(gcf),0,obj.max_speed,0,0);
                                
            catch
                fclose(obj.object);
                warning('Spectrometer:Interferometer', 'Cannot find translation stage.  Entering simulation mode.');
            end
        end

        %%
        function delete(obj)
            fclose(obj.object);
        end
        
        function new_position = MoveTo(obj, handles, desired_position, speed, move_relative, move_async)
            if move_relative
                pos = GetMotorPos(motor_index);         % @@@ Not right.  Need real position.
                desired_position = pos+desired_position;
            end

%             % Check against limits
%             new_position = desired_position+obj.center;
%             if new_position<obj.minimum
%                 new_position = obj.minimum;
%             elseif new_position>obj.maximum
%                 new_position = obj.maximum;
%             end
            desired_position_mm = obj.ValidatePosition(desired_position);
            
            if obj.initialized 

                %% move to an absolute position
                obj.sendPIMotorCommand(sprintf('VEL 1 %f', speed*obj.scale), 0);
                obj.sendPIMotorCommand(sprintf('MOV 1 %f', desired_position_mm), 0);

                %% Wait until stage reaches target
                if move_async==0
                    while obj.IsBusy
                      drawnow;
                      pause(0.1);
%                     while 1==1
%                         status = obj.sendPIMotorCommand('SRG? 1 1', 1);         % @@@@ change to use IsBusy
%                         num = uint16(hex2dec(status(7:end-1)));
%                         if bitand(num, hex2dec('A000'))==hex2dec('8000')
%                             break;
%                         else
%                             drawnow
%                             pause(0.1);     % Shortening this makes little difference
%                         end
                    end
                end

                %read where we arrived
                new_position = obj.GetPosition;
                %should we remove this??? or make the class own the edit.
                %That is probably best.
%                 if ~strcmp(obj.gui_object, '')
%                     h = eval(sprintf('handles.%s', obj.gui_object));
%                     set(h, 'String', num2str(new_position));
%                 end

            end
        end

        function MoveTwoStep(obj, pos1, pos2, speed)
            if obj.initialized
                obj.sendPIMotorCommand(sprintf('VEL 1 %f', speed*obj.scale), 0);
                obj.sendPIMotorCommand(sprintf('MAC START TWOSTEP %f %f', (pos1+obj.center)*obj.scale, (pos2+obj.center)*obj.scale), 0);
            end
        end
            
        function position = GetPosition(obj)
            if obj.initialized
                %what is the current position in hardware units?
                result = obj.sendPIMotorCommand('POS?', 1);
                [nums ~] = sscanf(result, '%i=%f');
                
                %convert to fs and shift origin
                position = nums(2)/obj.scale-obj.center;
            else
                position = 0;
            end
        end

        function SetCenter(obj)
            if obj.initialized
                %what is the current position in hardware units?
                result = obj.sendPIMotorCommand('POS?', 1);
                [nums ~] = sscanf(result, '%i=%f');
                
                %save that to center
                obj.center = nums(2)/obj.scale;
                
                %save that to a file
                obj.SaveResetPosition;
            end
        end
        
        function Halt(obj)
            fprintf(obj.object,'HLT 1\n');
        end
        
        function result = sendPIMotorCommand(obj, msg, expect_response)
            message = deblank(msg);

            if expect_response~=0
                result = query(obj.object, message);
            else
                result = '';
                fprintf(obj.object, message);
            end

% @@@ This should technically not go here.  Need to think out how 
% to guarantee that it will always be updated if put somewhere else.
            error_code = query(obj.object, 'ERR?');
            if error_code(1)~='0'
                error('Motor error code %s: %s\n', deblank(error_code), message);
            end
        end
        
        function busy = IsBusy(obj)
            if obj.initialized
                status = obj.sendPIMotorCommand('SRG? 1 1', 1);
                num = uint16(hex2dec(status(7:end-1)));
                busy = bitand(num, hex2dec('A000'))~=hex2dec('8000');
            else busy = 0;
            end
        end

        function LoadResetPosition(obj)
          fname = ['reset_' obj.gui_object '.mat'];
          if ~exist(fname,'file')==2
            warning('SGRLAB:NotImplemented','The reset file %s is not found on the path',fname);
          end
          load(fname);
          if s.scale~=obj.scale
            warning('SGRLAB:NotImplemented','The scales of the current %f and saved %f are different. Doing nothing.',obj.center,s.center);
            return
          end
          obj.center = s.center;
        end
        
        function SaveResetPosition(obj)
          warning('off','MATLAB:structOnObject');
          fullNameAndPath = mfilename('fullpath'); %name of this m-file
          [pathpart,~,~]=fileparts(fullNameAndPath);%we want path
          fname = [pathpart filesep 'reset_' obj.gui_object '.mat'];
          s = struct(obj);
          save(fname,'s');      
        end
        
        function s = LoadDefaults(obj)
        
        end
        
        function SaveDefaults(obj,s)
          
        end
        
        function new_position = ValidatePosition(obj,desired_position)
          % Check against limits
            new_position = desired_position+obj.center;
            if new_position<obj.minimum
                new_position = obj.minimum;
            elseif new_position>obj.maximum
                new_position = obj.maximum;
            end
            %convert to mm
            new_position = new_position*obj.scale;
        end
    end
    
end
