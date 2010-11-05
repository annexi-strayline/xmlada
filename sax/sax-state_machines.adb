-----------------------------------------------------------------------
--                XML/Ada - An XML suite for Ada95                   --
--                                                                   --
--                       Copyright (C) 2010, AdaCore                 --
--                                                                   --
-- This library is free software; you can redistribute it and/or     --
-- modify it under the terms of the GNU General Public               --
-- License as published by the Free Software Foundation; either      --
-- version 2 of the License, or (at your option) any later version.  --
--                                                                   --
-- This library is distributed in the hope that it will be useful,   --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of    --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU --
-- General Public License for more details.                          --
--                                                                   --
-- You should have received a copy of the GNU General Public         --
-- License along with this library; if not, write to the             --
-- Free Software Foundation, Inc., 59 Temple Place - Suite 330,      --
-- Boston, MA 02111-1307, USA.                                       --
--                                                                   --
-- As a special exception, if other files instantiate generics from  --
-- this unit, or you link this unit with other files to produce an   --
-- executable, this  unit  does not  by itself cause  the resulting  --
-- executable to be covered by the GNU General Public License. This  --
-- exception does not however invalidate any other reasons why the   --
-- executable file  might be covered by the  GNU Public License.     --
-----------------------------------------------------------------------

with Ada.Exceptions;         use Ada.Exceptions;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with GNAT.IO;                use GNAT.IO;
with Ada.Unchecked_Deallocation;

package body Sax.State_Machines is
   use Transition_Tables, State_Tables, Matcher_State_Arrays;

   Debug : constant Boolean := False;
   --  Whether to print on stdout the actions performed on the machine.
   --  Copy-pasting those actions would allow recreating the exact same
   --  machine.

   procedure Mark_Active
     (Self         : in out NFA_Matcher;
      List_Start   : in out Matcher_State_Index;
      From         : State;
      First_Nested : Matcher_State_Index := No_Matcher_State);
   --  Mark [From] as active next time, as well as all states reachable
   --  through an empty transition. THe nested state machine for the new state
   --  is set to [First_Nested].

   function Start_Match
     (Self : access NFA'Class; S : State) return NFA_Matcher;
   --  Returns a new matcher, initially in state [S] (and all empty transitions
   --  form it).

   function Nested_In_Final
     (Self : NFA_Matcher;
      S    : Matcher_State_Index) return Boolean;
   --  Return true if the nested NFA for [S] is in a final state, or if [S]
   --  has no nested automaton.
   --  [List_Start] is the first state in the level that contains [S]

   function Is_Active
     (Self       : NFA_Matcher;
      List_Start : Matcher_State_Index;
      S          : State) return Boolean;
   pragma Inline (Is_Active);
   --  Whether [S] is marked as active in the given list

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize
     (Self                 : in out NFA;
      States_Are_Statefull : Boolean := False)
   is
   begin
      Self.States_Are_Statefull := States_Are_Statefull;

      Init (Self.States);
      Init (Self.Transitions);

      --  Create start state
      Append
        (Self.States,
         State_Data'
           (Nested           => No_State,
            On_Nested_Exit   => No_Transition,
            First_Transition => No_Transition,
            Data             => Default_Data));
   end Initialize;

   ----------
   -- Free --
   ----------

   procedure Free (Self : in out NFA) is
   begin
      Free (Self.States);
      Free (Self.Transitions);
   end Free;

   ----------
   -- Free --
   ----------

   procedure Free (Automaton : in out NFA_Access) is
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (NFA'Class, NFA_Access);
   begin
      if Automaton /= null then
         Free (Automaton.all);
         Unchecked_Free (Automaton);
      end if;
   end Free;

   ----------
   -- Free --
   ----------

   procedure Free (Self : in out NFA_Matcher) is
   begin
      Free (Self.Active);
   end Free;

   ---------------
   -- Add_State --
   ---------------

   function Add_State
     (Self : access NFA; Data : State_User_Data := Default_Data) return State
   is
   begin
      Append
        (Self.States,
         State_Data'
           (Nested           => No_State,
            Data             => Data,
            On_Nested_Exit   => No_Transition,
            First_Transition => No_Transition));

      if Debug then
         Put_Line (Last (Self.States)'Img & " := NFA.Add_State");
      end if;

      return Last (Self.States);
   end Add_State;

   --------------
   -- Get_Data --
   --------------

   function Get_Data (Self : access NFA; S : State) return State_Data_Access is
   begin
      return Self.States.Table (S).Data'Access;
   end Get_Data;

   --------------------
   -- Add_Transition --
   --------------------

   procedure Add_Transition
     (Self      : access NFA;
      From      : State;
      To        : State;
      On_Symbol : Transition_Symbol) is
   begin
      if From = Final_State then
         Raise_Exception
           (Program_Error'Identity,
            "Can't add transitions from final_state");
      end if;

      Append
        (Self.Transitions,
         Transition'
           (Is_Empty       => False,
            To_State       => To,
            Next_For_State => Self.States.Table (From).First_Transition,
            Sym            => On_Symbol));
      Self.States.Table (From).First_Transition := Last (Self.Transitions);
   end Add_Transition;

   --------------------------
   -- Add_Empty_Transition --
   --------------------------

   procedure Add_Empty_Transition
     (Self : access NFA;
      From : State;
      To   : State)
   is
   begin
      if From = Final_State then
         Raise_Exception
           (Program_Error'Identity,
            "Can't add transitions from final_state");
      end if;

      Append
        (Self.Transitions,
         Transition'
           (Is_Empty       => True,
            To_State       => To,
            Next_For_State => Self.States.Table (From).First_Transition));
      Self.States.Table (From).First_Transition := Last (Self.Transitions);
   end Add_Empty_Transition;

   ------------
   -- Repeat --
   ------------

   procedure Repeat
     (Self       : access NFA;
      From, To   : State;
      Min_Occurs : Natural := 1;
      Max_Occurs : Positive := 1)
   is
      function Clone_And_Append (Newfrom : State) return State;
      --  Duplicate the automaton NewFrom..To
      --     -|Newfrom|--E--|To|--
      --  becomes
      --     -|Newfrom|--E--|Newto|--E--|To|
      --  and Newto is returned.

      procedure Rename_State (Old_State, New_State : State);
      --  Replace all references to [Old_State] with references to [New_State]
      --  This doesn't change transitions.

      function Add_Stateless return State;
      --  Add a new stateless (ie with no user data) state at the end of the
      --  subautomaton.
      --     -|From|--E--|To|--
      --  becomes
      --     -|From|--E--|N|--|To|
      --  where N is returned, has the user data of To, and To does not have
      --  any user data.

      ------------------
      -- Rename_State --
      ------------------

      procedure Rename_State (Old_State, New_State : State) is
      begin
         for T in Transition_Tables.First .. Last (Self.Transitions) loop
            if Self.Transitions.Table (T).To_State = Old_State then
               Self.Transitions.Table (T).To_State := New_State;
            end if;
         end loop;

         Self.States.Table (New_State).Nested  :=
           Self.States.Table (Old_State).Nested;
         Self.States.Table (Old_State).Nested := No_State;
      end Rename_State;

      ----------------------
      -- Clone_And_Append --
      ----------------------

      function Clone_And_Append (Newfrom : State) return State is
         New_To : constant State := Add_State (Self);

         Cloned : array (State_Tables.First .. Last (Self.States)) of State :=
           (others => No_State);
         --  Id of the clones corresponding to the states in Newfrom..To

         procedure Clone_Internal_Nodes (S : State);
         --  Clone all nodes internal to the subautomation.
         --  The algorithm is as follows: starting from [From], we follow all
         --  transitions until we reach [To]. We do not follow any transition
         --  from [To]. In the end, the internal nodes are the ones with an
         --  an entry in [Cloned].

         procedure Clone_Transitions;
         --  Clone all transitions for all cloned nodes. Only the transitions
         --  leading to internal nodes are cloned

         --------------------------
         -- Clone_Internal_Nodes --
         --------------------------

         procedure Clone_Internal_Nodes (S : State) is
            T   : Transition_Id;
         begin
            if S = Newfrom then
               Cloned (Newfrom) := New_To;
            elsif S = New_To then
               return;  --  Do not follow transitions from [To]
            else
               Cloned (S) := Add_State (Self, Self.States.Table (S).Data);
               Self.States.Table (Cloned (S)).Nested :=
                 Self.States.Table (S).Nested;
            end if;

            T := Self.States.Table (S).First_Transition;
            while T /= No_Transition loop
               declare
                  Tr : Transition renames Self.Transitions.Table (T);
               begin
                  if Tr.To_State = Final_State then
                     null;
                  elsif Cloned (Tr.To_State) = No_State then
                     Clone_Internal_Nodes (Tr.To_State);
                  end if;
                  T := Tr.Next_For_State;
               end;
            end loop;
         end Clone_Internal_Nodes;

         -----------------------
         -- Clone_Transitions --
         -----------------------

         procedure Clone_Transitions is
            procedure Do_Transitions
              (S : State; First : Transition_Id; On_Exit : Boolean);

            procedure Do_Transitions
              (S : State; First : Transition_Id; On_Exit : Boolean)
            is
               T   : Transition_Id;
               Tmp : State;
            begin
               T := First;
               while T /= No_Transition loop
                  declare
                     --  Not a "renames", because Self.Transitions might be
                     --  resized within this loop
                     Tr : constant Transition := Self.Transitions.Table (T);
                  begin
                     if Tr.To_State = Final_State then
                        Tmp := Final_State;
                        if Cloned (S) = To then
                           Tmp := No_State; --  No copy, will be done later
                        end if;
                     elsif Tr.To_State > Cloned'Last then
                        Tmp := No_State;  --  Link to the outside
                     else
                        Tmp := Cloned (Tr.To_State);
                     end if;

                     if Tmp /= No_State then
                        if Tr.Is_Empty then
                           if On_Exit then
                              On_Empty_Nested_Exit (Self, Cloned (S), Tmp);
                           else
                              Add_Empty_Transition (Self, Cloned (S), Tmp);
                           end if;
                        else
                           if On_Exit then
                              On_Nested_Exit (Self, Cloned (S), Tmp, Tr.Sym);
                           else
                              Add_Transition (Self, Cloned (S), Tmp, Tr.Sym);
                           end if;
                        end if;
                     end if;

                     T := Tr.Next_For_State;
                  end;
               end loop;
            end Do_Transitions;

            Prev : Transition_Id;
            T   : Transition_Id;
         begin
            Self.States.Table (New_To) := Self.States.Table (To);
            Self.States.Table (To).First_Transition := No_Transition;

            for S in reverse Cloned'Range loop
               if Cloned (S) /= No_State then
                  Do_Transitions
                    (S, Self.States.Table (S).First_Transition, False);
                  Do_Transitions
                    (S, Self.States.Table (S).On_Nested_Exit, True);
               end if;
            end loop;

            --  Last pass to move external transition from [New_To] to [To],
            --  ie from the end of the sub-automaton

            Prev := No_Transition;
            T := Self.States.Table (New_To).First_Transition;

            while T /= No_Transition loop
               declare
                  Tr : Transition renames Self.Transitions.Table (T);
                  Next : constant Transition_Id := Tr.Next_For_State;
               begin
                  if Tr.To_State = Final_State
                    or else
                      (Tr.To_State /= To
                       and then Tr.To_State <= Cloned'Last
                       and then Cloned (Tr.To_State) = No_State)
                  then
                     if Prev = No_Transition then
                        Self.States.Table (New_To).First_Transition :=
                          Tr.Next_For_State;
                     else
                        Self.Transitions.Table (Prev).Next_For_State :=
                          Tr.Next_For_State;
                     end if;

                     Tr.Next_For_State :=
                       Self.States.Table (To).First_Transition;
                     Self.States.Table (To).First_Transition := T;

                  else
                     Prev := T;
                  end if;

                  T := Next;
               end;
            end loop;
         end Clone_Transitions;

      begin
         --  Replace [To] with a new node, so that [To] is still
         --  the end state.

         Rename_State (To, New_To);

         --  Need to duplicate Newfrom..Newto into Newto..To

         Cloned (New_To) := To;
         Clone_Internal_Nodes (Newfrom);

         Clone_Transitions;

         return New_To;
      end Clone_And_Append;

      -------------------
      -- Add_Stateless --
      -------------------

      function Add_Stateless return State is
         N : State := To;
      begin
         if Self.States_Are_Statefull then
            --  Add extra stateless node
            N := Add_State (Self, Self.States.Table (To).Data);
            Self.States.Table (To).Data := Default_Data;

            Rename_State (To, N);
            Add_Empty_Transition (Self, N, To);
         end if;
         return N;
      end Add_Stateless;

      N : State;

   begin
      --  First the simple and usual cases (that cover the usual "*", "+" and
      --  "?" operators in regular expressions. It is faster to first handle
      --  those, since we don't need any additional new state for those.

      if Min_Occurs = 1 and then Max_Occurs = 1 then
         return;  --  Nothing to do
      elsif Min_Occurs > Max_Occurs then
         return;  --  As documented, nothing is done
      elsif Min_Occurs = 0 and then Max_Occurs = 1 then
         N := Add_Stateless;
         Add_Empty_Transition (Self, From, To);
         return;
      elsif Min_Occurs = 1 and then Max_Occurs = Natural'Last then
         Add_Empty_Transition (Self, From => To, To => From);
         return;
      elsif Min_Occurs = 0 and then Max_Occurs = Natural'Last then
         N := Add_Stateless;
         Add_Empty_Transition (Self, From, To);
         Add_Empty_Transition (Self, From => To, To => From);
         return;
      end if;

      --  We now deal with the more complex cases (always Max_Occurs > 1)

      N := From;

      if Max_Occurs = Natural'Last then
         for M in 1 .. Min_Occurs - 1 loop
            N := Clone_And_Append (N);  --  N_Prev..To becomes N_Prev..N..To
         end loop;
         Add_Empty_Transition (Self, To, N);  --  unlimited

      else
         declare
            Local_Ends : array (0 .. Max_Occurs - 1) of State;
         begin
            Local_Ends (0) := From;

            for M in 1 .. Max_Occurs - 1 loop
               N := Clone_And_Append (N);
               Local_Ends (M) := N;
            end loop;

            N := Add_Stateless;

            for L in Min_Occurs .. Local_Ends'Last loop
               Add_Empty_Transition (Self, Local_Ends (L), To);
            end loop;
         end;
      end if;
   end Repeat;

   ---------------
   -- Is_Active --
   ---------------

   function Is_Active
     (Self       : NFA_Matcher;
      List_Start : Matcher_State_Index;
      S          : State) return Boolean
   is
      T : Matcher_State_Index := List_Start;
   begin
      while T /= No_Matcher_State loop
         if Self.Active.Table (T).S = S then
            return True;
         end if;
         T := Self.Active.Table (T).Next;
      end loop;
      return False;
   end Is_Active;

   -----------------
   -- Mark_Active --
   -----------------

   procedure Mark_Active
     (Self         : in out NFA_Matcher;
      List_Start   : in out Matcher_State_Index;
      From         : State;
      First_Nested : Matcher_State_Index := No_Matcher_State)
   is
      T          : Transition_Id;
      From_Index : Matcher_State_Index;  --  Where we added [From]
   begin
      if Debug then
         Put_Line ("Mark_Active " & From'Img);
      end if;

      --  ??? Not very efficient, but the lists are expected to be short. We
      --  could try to use a state->boolean array, but then we need one such
      --  array for all nested NFA, which requires a lot of storage.

      if Is_Active (Self, List_Start, From) then
         return;
      end if;

      --  Always leave the Final_State first in the list

      if List_Start /= No_Matcher_State
        and then Self.Active.Table (List_Start).S = Final_State
      then
         Self.Active.Table (List_Start).S      := From;
         Self.Active.Table (List_Start).Nested := First_Nested;
         From_Index := List_Start;
         Append
           (Self.Active,
            Matcher_State'
              (S      => Final_State,
               Next   => List_Start,
               Nested => No_Matcher_State));
      else
         Append
           (Self.Active,
            Matcher_State'
              (S      => From,
               Next   => List_Start,
               Nested => First_Nested));
         From_Index := Last (Self.Active);
      end if;

      List_Start := Last (Self.Active);

      --  Mark (recursively) all states reachable from an empty transition
      --  as active too.

      if From /= Final_State then
         T := Self.NFA.States.Table (From).First_Transition;
         while T /= No_Transition loop
            declare
               Tr : Transition renames Self.NFA.Transitions.Table (T);
            begin
               if Tr.Is_Empty then
                  Mark_Active (Self, List_Start, Tr.To_State);
               end if;
               T := Tr.Next_For_State;
            end;
         end loop;

         --  If we are entering any state with a nested NFA, we should activate
         --  that NFA next turn (unless the nested NFA is already active)

         if Self.NFA.States.Table (From).Nested /= No_State
           and then Self.Active.Table (From_Index).Nested = No_Matcher_State
         then
            Mark_Active
              (Self,
               List_Start => Self.Active.Table (From_Index).Nested,
               From       => Self.NFA.States.Table (From).Nested);
         end if;
      end if;
   end Mark_Active;

   -----------------
   -- Start_Match --
   -----------------

   function Start_Match (Self : access NFA) return NFA_Matcher is
   begin
      return Start_Match (Self, S => Start_State);
   end Start_Match;

   -----------------
   -- Start_Match --
   -----------------

   function Start_Match
     (Self : access NFA'Class; S : State) return NFA_Matcher
   is
      R : NFA_Matcher;
   begin
      R.NFA          := NFA_Access (Self);
      R.First_Active := No_Matcher_State;
      Init (R.Active);
      Mark_Active (R, R.First_Active, S);
      return R;
   end Start_Match;

   ---------------------------
   -- For_Each_Active_State --
   ---------------------------

   procedure For_Each_Active_State
     (Self             : NFA_Matcher;
      Ignore_If_Nested : Boolean := False) is
   begin
      for S in 1 .. Last (Self.Active) loop
         if Self.Active.Table (S).S /= Final_State
           and then
             (Self.Active.Table (S).Nested = No_Matcher_State
              or else not Ignore_If_Nested
              or else Self.Active.Table (Self.Active.Table (S).Nested).S =
                Final_State)
         then
            Callback (Self.NFA, Self.Active.Table (S).S);
         end if;
      end loop;
   end For_Each_Active_State;

   -------------
   -- Process --
   -------------

   procedure Process
     (Self    : in out NFA_Matcher;
      Input   : Symbol;
      Success : out Boolean)
   is
      NFA   : constant NFA_Access := Self.NFA;
      Saved : constant Matcher_State_Arrays.Table_Type :=
        Self.Active.Table (1 .. Last (Self.Active));
      Saved_First_Active : constant Matcher_State_Index := Self.First_Active;

      procedure Process_Level
        (First     : Matcher_State_Index;
         New_First : in out Matcher_State_Index;
         Success   : out Boolean);
      --  Process all the nodes with a common parent (either all toplevel
      --  states, or all nested states within a specific state).

      procedure Process_Transitions
        (First        : Transition_Id;
         New_First    : in out Matcher_State_Index;
         Ignore_Empty : Boolean);
      --  Check all transitions from [First]

      -------------------------
      -- Process_Transitions --
      -------------------------

      procedure Process_Transitions
        (First        : Transition_Id;
         New_First    : in out Matcher_State_Index;
         Ignore_Empty : Boolean)
      is
         T : Transition_Id := First;
      begin
         while T /= No_Transition loop
            declare
               Tr : Transition renames NFA.Transitions.Table (T);
            begin
               if (Tr.Is_Empty and then not Ignore_Empty)
                 or else
                   (not Tr.Is_Empty
                    and then (not Is_Active (Self, New_First, Tr.To_State)
                              and then Match (Tr.Sym, Input)))
               then
                  Mark_Active (Self, New_First, Tr.To_State);
               end if;

               T := Tr.Next_For_State;
            end;
         end loop;
      end Process_Transitions;

      -------------------
      -- Process_Level --
      -------------------

      procedure Process_Level
        (First     : Matcher_State_Index;
         New_First : in out Matcher_State_Index;
         Success   : out Boolean)
      is
         N                : Matcher_State_Index := First;
         Event_Processed_In_Nested : Boolean;
         Nested_Final     : Boolean;
         S                : Matcher_State;
         Nested_First     : Matcher_State_Index;
         At_Current_Level : Matcher_State_Index;

      begin
         --  For each currently live state:
         --   - if there are nested NFA, we process these first. If the event
         --     is processed by them, it will not be passed on to the
         --     corresponding super state (event bubbling stopped).
         --   - if there are no nested NFA, or they did not process the event,
         --     the event is then processed directly by the super state.
         --  This corresponds to standard semantics of event bubbling in
         --  hierarchical NFA.

         while N /= No_Matcher_State loop
            S := Saved (N);
            Event_Processed_In_Nested := False;
            Nested_Final := True;

            if S.Nested /= No_Matcher_State then
               declare
                  Tmp : Matcher_State_Index := New_First;
               begin
                  At_Current_Level := No_Matcher_State;
                  while Tmp /= No_Matcher_State loop
                     if Self.Active.Table (Tmp).S = S.S then
                        At_Current_Level := Tmp;
                        exit;
                     end if;

                     Tmp := Self.Active.Table (Tmp).Next;
                  end loop;
               end;

               if At_Current_Level /= No_Matcher_State then
                  Process_Level
                    (First     => S.Nested,
                     New_First => Self.Active.Table (At_Current_Level).Nested,
                     Success   => Success);
                  Nested_First := Self.Active.Table (At_Current_Level).Nested;

               else
                  Nested_First := No_Matcher_State;
                  Process_Level (First     => S.Nested,
                                 New_First => Nested_First,
                                 Success   => Success);
               end if;

               if Success then
                  --  Exits the nested NFA, and thus transitions from its super
                  --  state. The super state, however, remains active until we
                  --  do transition from it.

                  Mark_Active (Self, New_First, S.S, Nested_First);
                  Nested_Final := Nested_In_Final (Self, Nested_First);
                  Event_Processed_In_Nested := True;

                  if Nested_Final then
                     Process_Transitions
                       (NFA.States.Table (S.S).On_Nested_Exit, New_First,
                        Ignore_Empty => False);
                  end if;

               else
                  Nested_Final := False;
                  --  Error: nothing matches anymore in the nested NFA. We
                  --  terminate it, but keep processing this event in its
                  --  superstate (for instance, a camera in state "on" has a
                  --  nested NFA "record"<->"play"). If the nested receives
                  --  the event "turn off", it won't match the nested, but
                  --  that's not an error because the event is handled by
                  --  the super state "on".
               end if;
            end if;

            if S.S /= Final_State
              and then not Event_Processed_In_Nested
            then
               Process_Transitions
                 (NFA.States.Table (S.S).First_Transition, New_First,
                  Ignore_Empty => True);
            end if;

            N := S.Next;
         end loop;

         Success := New_First /= No_Matcher_State;
      end Process_Level;

   begin
      --  Reset the matcher

      Set_Last (Self.Active, No_Matcher_State);
      Self.First_Active := No_Matcher_State;
      Process_Level (Saved_First_Active, Self.First_Active, Success);

      if not Success then
         Set_Last (Self.Active, Saved'Last);
         Self.Active.Table (1 .. Saved'Last) := Saved;
         Self.First_Active := Saved_First_Active;
      end if;
   end Process;

   ---------------------
   -- Nested_In_Final --
   ---------------------

   function Nested_In_Final
     (Self : NFA_Matcher;
      S    : Matcher_State_Index) return Boolean is
   begin
      return S = No_Matcher_State
        or else Self.Active.Table (S).S = Final_State;
   end Nested_In_Final;

   --------------
   -- Expected --
   --------------

   function Expected (Self : NFA_Matcher) return String is
      Msg : Unbounded_String;

      procedure Callback (The_NFA : access NFA'Class; S : State);
      procedure Callback (The_NFA : access NFA'Class; S : State) is
         T : Transition_Id := The_NFA.States.Table (S).First_Transition;
      begin
         while T /= No_Transition loop
            declare
               Tr : Transition renames The_NFA.Transitions.Table (T);
            begin
               if not Tr.Is_Empty then
                  if Msg /= Null_Unbounded_String then
                     Append (Msg, "|");
                  end if;

                  Append (Msg, Image (Tr.Sym));
               end if;

               T := Tr.Next_For_State;
            end;
         end loop;
      end Callback;

      procedure For_All_Active is new For_Each_Active_State (Callback);

   begin
      For_All_Active (Self);
      return To_String (Msg);
   end Expected;

   --------------
   -- In_Final --
   --------------

   function In_Final (Self : NFA_Matcher) return Boolean is
   begin
      return Nested_In_Final (Self, Self.First_Active);
   end In_Final;

   -------------------
   -- Create_Nested --
   -------------------

   function Create_Nested
     (Self : access NFA'Class; From : State) return Nested_NFA
   is
      pragma Unreferenced (Self);
   begin
      if Debug then
         Put_Line ("E := Create_Nested (" & From'Img & ")");
      end if;
      return (Default_Start => From);
   end Create_Nested;

   --------------------
   -- On_Nested_Exit --
   --------------------

   procedure On_Nested_Exit
     (Self      : access NFA;
      From      : State;
      To        : State;
      On_Symbol : Transition_Symbol) is
   begin
      Append
        (Self.Transitions,
         Transition'
           (Is_Empty       => False,
            To_State       => To,
            Next_For_State => Self.States.Table (From).On_Nested_Exit,
            Sym            => On_Symbol));
      Self.States.Table (From).On_Nested_Exit := Last (Self.Transitions);
   end On_Nested_Exit;

   --------------------------
   -- On_Empty_Nested_Exit --
   --------------------------

   procedure On_Empty_Nested_Exit
     (Self      : access NFA;
      From      : State;
      To        : State) is
   begin
      Append
        (Self.Transitions,
         Transition'
           (Is_Empty       => True,
            To_State       => To,
            Next_For_State => Self.States.Table (From).On_Nested_Exit));
      Self.States.Table (From).On_Nested_Exit := Last (Self.Transitions);
   end On_Empty_Nested_Exit;

   ----------------
   -- Set_Nested --
   ----------------

   procedure Set_Nested (Self : access NFA; S : State; Nested : Nested_NFA) is
   begin
      if Debug then
         Put_Line
           ("Set_Nested (" & S'Img & "," & Nested.Default_Start'Img & ")");
      end if;
      Self.States.Table (S).Nested := Nested.Default_Start;
   end Set_Nested;

   ----------------
   -- Get_Nested --
   ----------------

   function Get_Nested (Self : access NFA; S : State) return Nested_NFA is
   begin
      return Nested_NFA'(Default_Start => Self.States.Table (S).Nested);
   end Get_Nested;

   -------------------
   -- Default_Image --
   -------------------

   function Default_Image (S : State; Data : State_User_Data) return String is
      pragma Unreferenced (Data);
      Str : constant String := State'Image (S);
   begin
      return "S" & Str (Str'First + 1 .. Str'Last);
   end Default_Image;

   ---------------------
   -- Pretty_Printers --
   ---------------------

   package body Pretty_Printers is

      function Node_Label
        (Self : access NFA'Class;
         S    : State) return String;
      function Node_Name
        (S : State; Nested_In : State := No_State) return String;
      procedure Append_Node
        (Self : access NFA'Class;
         S : State; R : in out Unbounded_String;
         Nested_In : State := No_State);

      ---------------
      -- Node_Name --
      ---------------

      function Node_Name
        (S : State; Nested_In : State := No_State) return String is
      begin
         if S = Start_State then
            return "Start";
         elsif S = Final_State then
            if Nested_In /= No_State then
               return "Sf" & Node_Name (Nested_In);
            else
               return "Sf";
            end if;
         else
            return Default_Image (S, Default_Data);
         end if;
      end Node_Name;

      ----------------
      -- Node_Label --
      ----------------

      function Node_Label
        (Self : access NFA'Class;
         S    : State) return String is
      begin
         if S = Start_State then
            return "Start";
         elsif S = Final_State then
            return "Final";
         else
            declare
               Img : constant String :=
                 State_Image (S, Self.States.Table (S).Data);
            begin
               if Img = "" then
                  if Self.States.Table (S).Nested /= No_State then
                     return Node_Name (S)
                       & ":" & Node_Label (Self, Self.States.Table (S).Nested);
                  else
                     return Node_Name (S);
                  end if;
               else
                  if Self.States.Table (S).Nested /= No_State then
                     return Node_Name (S) & "_" & Img
                       & ":" & Node_Label (Self, Self.States.Table (S).Nested);
                  else
                     return Node_Name (S) & "_" & Img;
                  end if;
               end if;
            end;
         end if;
      end Node_Label;

      -----------------
      -- Append_Node --
      -----------------

      procedure Append_Node
        (Self : access NFA'Class;
         S : State; R : in out Unbounded_String;
         Nested_In : State := No_State)
      is
         Name  : constant String := Node_Name (S, Nested_In);
         Label : constant String := Node_Label (Self, S);
      begin
         Append (R, Name);
         if Label /= Name then
            if S = Start_State
              or else S = Final_State
              or else S = Nested_In
            then
               if Label /= "" then
                  Append (R, "[label=""" & Label & """ shape=doublecircle];");
               else
                  Append (R, "[shape=doublecircle];");
               end if;
            elsif Label /= "" then
               Append (R, "[label=""" & Label & """];");
            else
               Append (R, ";");
            end if;
         else
            if S = Start_State or else S = Nested_In then
               Append (R, "[shape=doublecircle];");
            else
               Append (R, ";");
            end if;
         end if;
      end Append_Node;

      ----------
      -- Dump --
      ----------

      function Dump
        (Self   : access NFA'Class;
         Nested : Nested_NFA;
         Mode   : Dump_Mode := Dump_Compact) return String
      is
         Dumped : array (State_Tables.First .. Last (Self.States)) of Boolean
           := (others => False);
         Result : Unbounded_String;

         procedure Internal (S : State);

         procedure Internal (S : State) is
            T : Transition_Id;
         begin
            if Dumped (S) then
               return;
            end if;

            Dumped (S) := True;
            Append (Result, " " & Node_Label (Self, S));

            T := Self.States.Table (S).First_Transition;
            while T /= No_Transition loop
               declare
                  Tr : Transition renames Self.Transitions.Table (T);
               begin
                  if Tr.Is_Empty then
                     Append (Result, "(");
                  else
                     Append (Result, "(" & Image (Tr.Sym));
                  end if;

                  Append (Result, "," & Node_Name (Tr.To_State) & ")");

                  T := Tr.Next_For_State;
               end;
            end loop;

            T := Self.States.Table (S).On_Nested_Exit;
            while T /= No_Transition loop
               declare
                  Tr : Transition renames Self.Transitions.Table (T);
               begin
                  if Tr.Is_Empty then
                     Append (Result, "(Exit");
                  else
                     Append (Result, "(Exit_" & Image (Tr.Sym));
                  end if;

                  Append (Result, "," & Node_Name (Tr.To_State) & ")");

                  T := Tr.Next_For_State;
               end;
            end loop;

            T := Self.States.Table (S).First_Transition;
            while T /= No_Transition loop
               declare
                  Tr : Transition renames Self.Transitions.Table (T);
               begin
                  if Tr.To_State /= Final_State then
                     Internal (Tr.To_State);
                  end if;
                  T := Tr.Next_For_State;
               end;
            end loop;

            T := Self.States.Table (S).On_Nested_Exit;
            while T /= No_Transition loop
               declare
                  Tr : Transition renames Self.Transitions.Table (T);
               begin
                  if Tr.To_State /= Final_State then
                     Internal (Tr.To_State);
                  end if;
                  T := Tr.Next_For_State;
               end;
            end loop;

            if Mode = Dump_Multiline then
               Append (Result, ASCII.LF);
            end if;

            if Self.States.Table (S).Nested /= No_State
              and then not Dumped (Self.States.Table (S).Nested)
            then
               Internal (Self.States.Table (S).Nested);
            end if;
         end Internal;

      begin
         Internal (Nested.Default_Start);
         return To_String (Result);
      end Dump;

      ----------
      -- Dump --
      ----------

      function Dump
        (Self                : access NFA'Class;
         Mode                : Dump_Mode := Dump_Compact;
         Show_Details        : Boolean := True;
         Show_Isolated_Nodes : Boolean := True) return String
      is
         Dumped : array (State_Tables.First .. Last (Self.States)) of Boolean
           := (others => False);

         Result : Unbounded_String;

         procedure Newline;
         --  Append a newline to [Result] if needed

         procedure Dump_Dot (Start_At, Nested_In : State; Prefix : String);
         procedure Dump_Dot_Transitions
           (S : State; First : Transition_Id; Prefix : String;
            Label_Prefix : String; Nested_In : State := No_State);

         procedure Dump_Nested (S : State);
         --  Dump a cluster that represents a nested NFA.
         --  Such nested NFAs are represented only once, even though they can
         --  in fact be nested within several nodes. That would make huge
         --  graphs otherwise.

         -------------
         -- Newline --
         -------------

         procedure Newline is
         begin
            case Mode is
            when Dump_Compact | Dump_Dot_Compact => null;
            when others => Append (Result, ASCII.LF);
            end case;
         end Newline;

         --------------------------
         -- Dump_Dot_Transitions --
         --------------------------

         procedure Dump_Dot_Transitions
           (S : State; First : Transition_Id; Prefix : String;
            Label_Prefix : String; Nested_In : State := No_State)
         is
            T : Transition_Id := First;
         begin
            while T /= No_Transition loop
               declare
                  Tr : Transition renames Self.Transitions.Table (T);
               begin
                  Append (Result,
                          Prefix & Node_Name (S, Nested_In)
                          & "->" & Node_Name (Tr.To_State, Nested_In)
                          & "[");

                  if not Tr.Is_Empty then
                     Append
                       (Result,
                        "label=""" & Label_Prefix & Image (Tr.Sym) & """");

                     if Label_Prefix = "on_exit:" then
                        Append (Result, " style=dotted");
                     end if;
                  else
                     if Label_Prefix /= "" then
                        Append (Result, "label=""" & Label_Prefix & """ ");
                     end if;

                     if Label_Prefix = "on_exit:" then
                        Append (Result, "style=dotted");
                     else
                        Append (Result, "style=dashed");
                     end if;
                  end if;

                  Append (Result, "];");
                  Newline;

                  if Tr.To_State /= Final_State then
                     Dump_Dot (Tr.To_State, Nested_In, Prefix);
                  end if;

                  T := Tr.Next_For_State;
               end;
            end loop;
         end Dump_Dot_Transitions;

         -----------------
         -- Dump_Nested --
         -----------------

         procedure Dump_Nested (S : State) is
            Name  : constant String := Node_Name (S);
            Label : constant String := Node_Label (Self, S);
         begin
            Append (Result, "subgraph cluster" & Name & "{");
            Newline;
            Append (Result, " label=""" & Label & """;");
            Newline;
            Append_Node (Self, S, Result, S);
            Append_Node (Self, Final_State, Result, S);

            Dump_Dot (S, Prefix => " ", Nested_In => S);

            Append (Result, "};");
            Newline;
         end Dump_Nested;

         --------------
         -- Dump_Dot --
         --------------

         procedure Dump_Dot (Start_At, Nested_In : State; Prefix : String) is
         begin
            if Start_At = Final_State or else Dumped (Start_At) then
               return;
            end if;
            Dumped (Start_At) := True;
            Dump_Dot_Transitions
              (Start_At,
               Self.States.Table (Start_At).First_Transition, Prefix, "",
               Nested_In);
            Dump_Dot_Transitions
              (Start_At,
               Self.States.Table (Start_At).On_Nested_Exit, Prefix, "on_exit:",
               Nested_In);
         end Dump_Dot;

      begin
         Append (Result, "Total states:" & Last (Self.States)'Img
                 & ASCII.LF);
         Append (Result, "Total transitions:" & Last (Self.Transitions)'Img
                 & ASCII.LF);

         if not Show_Details then
            return To_String (Result);
         end if;

         case Mode is
         when Dump_Multiline | Dump_Compact =>
            return Dump (Self   => Self,
                         Nested => (Default_Start => Start_State),
                         Mode   => Mode);

         when Dump_Dot | Dump_Dot_Compact =>
            Append (Result, "Use   dot -O -Tpdf file.dot" & ASCII.LF);
            Append (Result, "digraph finite_state_machine{");
            Newline;
            Append (Result, "compound=true;");
            Newline;
            Append (Result, "rankdir=LR;");
            Newline;
            Append_Node (Self, Start_State, Result);
            Append_Node (Self, Final_State, Result);

            --  First, create all the clusters for the nested NFA. That helps
            --  remove their states from the global lists, so that we can then
            --  only dump the toplevel states

            for S in State_Tables.First .. Last (Self.States) loop
               if Self.States.Table (S).Nested /= No_State then
                  Dump_Nested (Self.States.Table (S).Nested);
               end if;
            end loop;

            --  Now dump the labels for all nodes. These do not need to go
            --  into the clusters, as long as the nodes where first encountered
            --  there

            for S in State_Tables.First .. Last (Self.States) loop
               if Show_Isolated_Nodes
                 or else Self.States.Table (S).Nested /= No_State
                 or else Self.States.Table (S).First_Transition /=
                   No_Transition
               then
                  Append_Node (Self, S, Result);
               end if;
            end loop;

            --  Now dump the toplevel states (that is the ones that haven't
            --  been dumped yet)

            for S in State_Tables.First .. Last (Self.States) loop
               if Show_Isolated_Nodes
                 or else Self.States.Table (S).Nested /= No_State
                 or else Self.States.Table (S).First_Transition /=
                   No_Transition
               then
                  Dump_Dot (S, No_State, "");
               end if;
            end loop;

            Append (Result, "}" & ASCII.LF);
         end case;

         return To_String (Result);
      end Dump;

      -----------------
      -- Debug_Print --
      -----------------

      procedure Debug_Print
        (Self   : NFA_Matcher;
         Mode   : Dump_Mode := Dump_Multiline;
         Prefix : String := "")
      is
         NFA : constant NFA_Access := Self.NFA;

         procedure Internal (From : Matcher_State_Index; Prefix : String);

         procedure Internal (From : Matcher_State_Index; Prefix : String) is
            F : Matcher_State_Index := From;
         begin
            while F /= No_Matcher_State loop
               Put (Node_Label (NFA, Self.Active.Table (F).S));

               if Self.Active.Table (F).Nested /= No_Matcher_State then
                  if Mode = Dump_Multiline then
                     New_Line;
                  end if;
                  Put (Prefix & " [");

                  if Mode = Dump_Multiline then
                     Internal (Self.Active.Table (F).Nested, Prefix & "  ");
                  else
                     Internal (Self.Active.Table (F).Nested, Prefix);
                  end if;

                  Put ("]");
               end if;

               F := Self.Active.Table (F).Next;

               if F /= No_Matcher_State then
                  Put (" ");
               end if;
            end loop;
         end Internal;

      begin
         if Self.First_Active = No_Matcher_State then
            Put_Line (Prefix & "[no active state]");
         else
            Put (Prefix);
            Internal (Self.First_Active, "");
            New_Line;
         end if;
      end Debug_Print;
   end Pretty_Printers;

   ---------------------
   -- Get_Start_State --
   ---------------------

   function Get_Start_State (Self : Nested_NFA) return State is
   begin
      return Self.Default_Start;
   end Get_Start_State;

end Sax.State_Machines;