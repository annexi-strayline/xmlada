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

pragma Ada_05;

with Ada.Unchecked_Deallocation;
with GNAT.Dynamic_Tables;
with GNAT.Regpat;         use GNAT.Regpat;
with Sax.Locators;        use Sax.Locators;
with Sax.Symbols;         use Sax.Symbols;
with Sax.Utils;           use Sax.Utils;
with Schema.Decimal;      use Schema.Decimal;
with Schema.Date_Time;    use Schema.Date_Time;
with Unicode.CES;         use Unicode.CES;

package Schema.Simple_Types is

   type Simple_Type_Index is new Natural;
   No_Simple_Type_Index : constant Simple_Type_Index := 0;

   type Enumeration_Index is new Natural;
   No_Enumeration_Index : constant Enumeration_Index := 0;

   Max_Types_In_Union : constant := 9;
   --  Maximum number of types in a union.
   --  This is hard-coded to avoid memory allocations as much as possible.
   --  This value is chosen so that the case [Facets_Union] does not make
   --  [Simple_Type_Descr] bigger than the other cases.

   type Whitespace_Restriction is (Preserve, Replace, Collapse);

   function Convert_Regexp
     (Regexp : Unicode.CES.Byte_Sequence) return String;
   --  Return a regular expresssion that converts the XML-specification
   --  regexp Regexp to a GNAT.Regpat compatible one

   type Primitive_Simple_Type_Kind is
     (Facets_Boolean, Facets_Double, Facets_Decimal,
      Facets_Float,

      Facets_String, Facets_Any_URI, Facets_QName,
      Facets_Notation, Facets_NMTOKEN, Facets_Language,
      Facets_NMTOKENS, Facets_Name, Facets_NCName, Facets_NCNames,
      Facets_Base64Binary, Facets_HexBinary,

      Facets_Time, Facets_DateTime, Facets_GDay, Facets_GMonthDay,
      Facets_GMonth, Facets_GYearMonth, Facets_GYear, Facets_Date,
      Facets_Duration,

      Facets_Union, Facets_List
     );

   type Pattern_Matcher_Access is access GNAT.Regpat.Pattern_Matcher;
   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (Pattern_Matcher, Pattern_Matcher_Access);

   type Simple_Type_Array is array (Natural range <>) of Simple_Type_Index;

   type Simple_Type_Descr
     (Kind : Primitive_Simple_Type_Kind := Facets_Boolean)
   is record
      Pattern_String : Sax.Symbols.Symbol     := Sax.Symbols.No_Symbol;
      Pattern        : Pattern_Matcher_Access := null;
      Whitespace     : Whitespace_Restriction := Collapse;
      Enumeration    : Enumeration_Index      := No_Enumeration_Index;

      case Kind is
         when Facets_Union =>
            Union : Simple_Type_Array (1 .. Max_Types_In_Union) :=
              (others => No_Simple_Type_Index);

         when Facets_List =>
            List_Item : Simple_Type_Index;

         when Facets_String .. Facets_HexBinary =>
            String_Length      : Natural := Natural'Last;
            String_Min_Length  : Natural := 0;
            String_Max_Length  : Natural := Natural'Last;

         when Facets_Boolean =>
            null;

         when Facets_Float | Facets_Double  =>  --  float, double
            Float_Min_Inclusive : XML_Float := Unknown_Float;
            Float_Max_Inclusive : XML_Float := Unknown_Float;
            Float_Min_Exclusive : XML_Float := Unknown_Float;
            Float_Max_Exclusive : XML_Float := Unknown_Float;

         when Facets_Decimal =>  --  decimal
            Total_Digits          : Positive := Positive'Last;
            Fraction_Digits       : Natural  := Natural'Last;
            Decimal_Min_Inclusive, Decimal_Max_Inclusive,
            Decimal_Min_Exclusive, Decimal_Max_Exclusive :
            Arbitrary_Precision_Number := Undefined_Number;

         when Facets_Time =>
            Time_Min_Inclusive, Time_Min_Exclusive,
            Time_Max_Inclusive, Time_Max_Exclusive  : Time_T := No_Time_T;

         when Facets_DateTime =>
            DateTime_Min_Inclusive, DateTime_Min_Exclusive,
            DateTime_Max_Inclusive, DateTime_Max_Exclusive  : Date_Time_T :=
              No_Date_Time;

         when Facets_GDay =>
            GDay_Min_Inclusive, GDay_Min_Exclusive,
            GDay_Max_Inclusive, GDay_Max_Exclusive  : GDay_T := No_GDay;

         when Facets_GMonthDay =>
            GMonthDay_Min_Inclusive, GMonthDay_Min_Exclusive,
            GMonthDay_Max_Inclusive, GMonthDay_Max_Exclusive : GMonth_Day_T
              := No_Month_Day;

         when Facets_GMonth =>
            GMonth_Min_Inclusive, GMonth_Min_Exclusive,
            GMonth_Max_Inclusive, GMonth_Max_Exclusive  : GMonth_T :=
              No_Month;

         when Facets_GYearMonth =>
            GYearMonth_Min_Inclusive, GYearMonth_Min_Exclusive,
            GYearMonth_Max_Inclusive, GYearMonth_Max_Exclusive :
              GYear_Month_T := No_Year_Month;

         when Facets_GYear =>
            GYear_Min_Inclusive, GYear_Min_Exclusive,
            GYear_Max_Inclusive, GYear_Max_Exclusive  : GYear_T := No_Year;

         when Facets_Date =>
            Date_Min_Inclusive, Date_Min_Exclusive,
            Date_Max_Inclusive, Date_Max_Exclusive  : Date_T := No_Date_T;

         when Facets_Duration =>
            Duration_Min_Inclusive, Duration_Min_Exclusive,
            Duration_Max_Inclusive, Duration_Max_Exclusive  : Duration_T :=
              No_Duration;
      end case;
   end record;

   package Simple_Type_Tables is new GNAT.Dynamic_Tables
     (Table_Component_Type => Simple_Type_Descr,
      Table_Index_Type     => Simple_Type_Index,
      Table_Low_Bound      => No_Simple_Type_Index + 1,
      Table_Initial        => 100,
      Table_Increment      => 100);

   subtype Simple_Type_Table is Simple_Type_Tables.Instance;

   type Enumeration_Descr is record
      Value : Sax.Symbols.Symbol;
      Next  : Enumeration_Index := No_Enumeration_Index;
   end record;

   package Enumeration_Tables is new GNAT.Dynamic_Tables
     (Table_Component_Type => Enumeration_Descr,
      Table_Index_Type     => Enumeration_Index,
      Table_Low_Bound      => No_Enumeration_Index + 1,
      Table_Initial        => 30,
      Table_Increment      => 20);

   generic
      with procedure Register
        (Local : Unicode.CES.Byte_Sequence;
         Descr : Simple_Type_Descr);
   procedure Register_Predefined_Types (Symbols : Sax.Utils.Symbol_Table);
   --  Register all the predefined types

   function Validate_Simple_Type
     (Simple_Types  : Simple_Type_Table;
      Enumerations  : Enumeration_Tables.Instance;
      Symbols       : Sax.Utils.Symbol_Table;
      Simple_Type   : Simple_Type_Index;
      Ch            : Unicode.CES.Byte_Sequence;
      Empty_Element : Boolean) return Sax.Symbols.Symbol;
   --  Validate [Ch] for the simple type [Simple_Type].
   --  Returns an error message in case of error, or No_Symbol otherwise

   function Equal
     (Simple_Types  : Simple_Type_Table;
      Symbols       : Symbol_Table;
      Simple_Type   : Simple_Type_Index;
      Ch1           : Sax.Symbols.Symbol;
      Ch2           : Unicode.CES.Byte_Sequence) return Boolean;
   --  Checks whether [Ch1]=[Ch2] according to the type.
   --  (This involves for instance normalizing whitespaces)

   type Facet_Enum is (Facet_Whitespace,
                       Facet_Enumeration,
                       Facet_Pattern,
                       Facet_Min_Inclusive,
                       Facet_Max_Inclusive,
                       Facet_Min_Exclusive,
                       Facet_Max_Exclusive,
                       Facet_Length,
                       Facet_Min_Length,
                       Facet_Max_Length,
                       Facet_Total_Digits,
                       Facet_Fraction_Digits);
   type Facet_Value is record
      Value : Sax.Symbols.Symbol := Sax.Symbols.No_Symbol;
      Enum  : Enumeration_Index := No_Enumeration_Index;
      Loc   : Sax.Locators.Location;
   end record;
   No_Facet_Value : constant Facet_Value := (Sax.Symbols.No_Symbol,
                                             No_Enumeration_Index,
                                             Sax.Locators.No_Location);

   type All_Facets is array (Facet_Enum) of Facet_Value;
   No_Facets : constant All_Facets := (others => No_Facet_Value);
   --  A temporary record to hold facets defined in a schema, until we can
   --  merge them with the base's facets. It does not try to interpret the
   --  facets.

   procedure Add_Facet
     (Facets       : in out All_Facets;
      Symbols      : Sax.Utils.Symbol_Table;
      Enumerations : in out Enumeration_Tables.Instance;
      Facet_Name   : Sax.Symbols.Symbol;
      Value        : Sax.Symbols.Symbol;
      Loc          : Sax.Locators.Location);
   --  Set a specific facet in [Simple]

   procedure Override
     (Simple     : in out Simple_Type_Descr;
      Facets     : All_Facets;
      Symbols    : Sax.Utils.Symbol_Table;
      Error      : out Sax.Symbols.Symbol;
      Error_Loc  : out Sax.Locators.Location);
   --  Override [Simple] with the facets defined in [Facets], but keep those
   --  facets that are not defined. Sets [Error] to a symbol if one of the
   --  facets is invalid for [Simple].

end Schema.Simple_Types;